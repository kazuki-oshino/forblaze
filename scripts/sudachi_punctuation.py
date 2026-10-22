"""句読点のない全文から候補を生成する探索実験。本文は正規化して書き換えない。"""

from difflib import SequenceMatcher
import json
from pathlib import Path
import re
import time

from punctuation_eval import ROOT, render
from punctuation_ensemble import split_cases

MARKS = {'comma': '、', 'period': '。', 'none': ''}
GREETINGS = ('こんにちは', 'こんばんは', 'おはようございます', '初めまして', 'はじめまして',
             '失礼します', 'すみません', '申し訳ありません', 'ありがとうございます', 'はい', 'ええ')
COMPANIES = ('株式会社', '有限会社', '合同会社', '一般社団法人', '医療法人')


def split_punctuation(text):
    chars, marks = [], {}
    for char in text:
        if char in '、。':
            if len(chars) in marks:
                raise ValueError('同じ位置の句読点が重複')
            marks[len(chars)] = char
        else:
            chars.append(char)
    return ''.join(chars), marks


def apply_punctuation(text, marks):
    if any(type(i) is not int or not 0 <= i <= len(text) or m not in '、。' or len(m) != 1
           for i, m in marks.items()):
        raise ValueError('句読点または位置が不正')
    return marks.get(0, '') + ''.join(c + marks.get(i + 1, '') for i, c in enumerate(text))


def score_text(gold, predicted):
    # ASRの空白表記は評価から除外する。変換器自体は空白を保持する。
    gold, predicted = re.sub(r'\s', '', gold), re.sub(r'\s', '', predicted)
    g, gm = split_punctuation(gold)
    p, pm = split_punctuation(predicted)
    matcher = SequenceMatcher(None, p, g, autojunk=False)
    alignment = {a + k: b + k for a, b, n in matcher.get_matching_blocks() for k in range(n)}
    mapped, unaligned = set(), 0
    for pos, mark in pm.items():
        if pos == len(p) and pos > 0 and alignment.get(pos - 1) == len(g) - 1:
            mapped.add((len(g), mark))
        elif pos > 0 and pos < len(p) and pos - 1 in alignment and alignment.get(pos) == alignment[pos - 1] + 1:
            mapped.add((alignment[pos], mark))
        else:
            unaligned += 1
    expected = set(gm.items())
    tp = len(mapped & expected)
    previous = list(range(len(g) + 1))
    for i, a in enumerate(p, 1):
        current = [i]
        for j, b in enumerate(g, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return {'exact': predicted == gold, 'lexical_exact': p == g,
            'tp': tp, 'fp': len(pm) - tp, 'fn': len(gm) - tp,
            'gold_marks': len(gm), 'predicted_marks': len(pm), 'unaligned_marks': unaligned,
            'character_edits': previous[-1], 'gold_characters': len(g)}


def aggregate(scores):
    keys = ('tp', 'fp', 'fn', 'gold_marks', 'predicted_marks', 'unaligned_marks', 'character_edits', 'gold_characters')
    result = {k: sum(s[k] for s in scores) for k in keys}
    result.update(count=len(scores), exact=sum(s['exact'] for s in scores), lexical_exact=sum(s['lexical_exact'] for s in scores))
    tp, fp, fn = (result[k] for k in ('tp', 'fp', 'fn'))
    result.update(precision=tp / (tp + fp) if tp + fp else 0,
                  recall=tp / (tp + fn) if tp + fn else 0,
                  f1=2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else 1,
                  cer=result['character_edits'] / max(1, result['gold_characters']))
    return result


def build_corpus():
    groups = split_cases()
    result = {}
    for output, source in [('development', 'development'), ('evaluation', 'holdout')]:
        result[output] = []
        for case in groups[source]:
            if case['preferred'] is None:
                continue
            gold = render(case, case['preferred'])
            raw, marks = split_punctuation(gold)
            result[output].append({'id': case['id'], 'category': case['category'], 'gold': gold,
                'text': raw, 'gold_marks': marks,
                'allowed_texts': [render(case, option) for option in case['allowed']]})
    return result


class Analyzer:
    def __init__(self):
        from sudachipy import dictionary, tokenizer
        self.dictionary = dictionary.Dictionary(dict='core')
        self.tokenizer = self.dictionary.create()
        self.mode = tokenizer.Tokenizer.SplitMode.C

    def analyze(self, text):
        if '、' in text or '。' in text:
            raise ValueError('入力は句読点なしの全文')
        started = time.perf_counter()
        tokens = [{'surface': m.surface(), 'begin': m.begin(), 'end': m.end(),
                   'pos': list(m.part_of_speech()), 'oov': m.is_oov()}
                  for m in self.tokenizer.tokenize(text, self.mode)]
        for token in tokens:
            if text[token['begin']:token['end']] != token['surface']:
                raise ValueError('原文と形態素の位置が不一致')
        protected = [(m.start(), m.end()) for m in re.finditer(r'https?://[^\s「」『』（）]+|[\w.+-]+@[\w.-]+', text)]
        candidates, marks = [], {}
        for i, left in enumerate(tokens[:-1]):
            right = tokens[i + 1]
            pos = left['end']
            lp, rp = left['pos'], right['pos']
            prefix = text[:pos]
            # 語の内部・助詞や助動詞の前・補助動詞連鎖は判定対象にしない。
            blocked = (any(a < pos < b for a, b in protected)
                       or rp[0] in ('助詞', '助動詞', '接尾辞', '空白')
                       or lp[0] in ('接頭辞', '連体詞', '空白')
                       or lp[1] == '括弧開' or rp[1] == '括弧閉'
                       or (rp[0] == '動詞' and rp[1] == '非自立可能' and
                           (lp[0] == '動詞' or left['surface'] in ('て', 'で') or 'サ変' in lp[2]))
                       or (lp[0] == '名詞' and lp[1] == '数詞')
                       or any(prefix.endswith(name) for name in COMPANIES)
                       or (lp[0] == '名詞' and lp[1] == '固有名詞' and rp[0] in ('名詞', '接尾辞'))
                       or (re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', left['surface']) is not None and rp[0] == '名詞'))
            if blocked:
                continue
            greeting = any(prefix.endswith(s) for s in GREETINGS)
            conditional = (prefix.endswith(('ので', 'のに', 'けれど', 'けど', 'たら', 'なら'))
                           or left['surface'] == 'ば')
            terminal = (prefix.endswith(('です', 'ます', 'でした', 'ました', 'ません', 'ください', 'でしょう'))
                        or (lp[0] in ('動詞', '形容詞', '助動詞') and lp[5].startswith(('終止形', '命令形'))))
            conjunct = lp[0] == '助詞' and lp[1] == '接続助詞' and left['surface'] in ('て', 'で', 'が', 'から')
            kind = ('greeting' if greeting else 'dependent' if conditional else
                    'terminal' if terminal else 'conjunct' if conjunct else 'noun_pair'
                    if lp[0] == rp[0] == '名詞' else 'phrase')
            # 列挙と複合語の区別を一律の名詞連接ルールにしない。候補は残し既定は挿入なし。
            if kind == 'phrase' and lp[0] not in ('助詞', '動詞', '形容詞', '助動詞', '感動詞', '補助記号'):
                continue
            default = 'comma' if kind in ('greeting', 'dependent', 'conjunct') else 'period' if kind == 'terminal' else 'none'
            permitted = ['comma', 'none'] if not terminal else ['comma', 'period', 'none']
            candidate = {'offset': pos, 'kind': kind, 'rule': default, 'permitted': permitted,
                         'left_tokens': tokens[max(0, i - 1):i + 1], 'right_tokens': tokens[i + 1:i + 3]}
            candidates.append(candidate)
            if MARKS[default]: marks[pos] = MARKS[default]
        if tokens:
            last = tokens[-1]
            if ((last['pos'][0] in ('動詞', '形容詞', '助動詞') and last['pos'][5].startswith(('終止形', '命令形', '意志推量形')))
                    or last['pos'][1] == '終助詞'):
                marks[len(text)] = '。'
        return {'text': text, 'tokens': tokens, 'candidates': candidates, 'rule_marks': marks,
                'rule_text': apply_punctuation(text, marks), 'analysis_ms': (time.perf_counter() - started) * 1000}


def requests_for(plan):
    result = []
    instructions = {
        'comma': 'Would a Japanese comma at the boundary improve readability without splitting a word, name or predicate? Use a comma between a greeting and self-introduction.',
        'period': 'Does the boundary separate two independent complete sentences, so a Japanese full stop is appropriate?',
        'none': 'Is directly joining LEFT and RIGHT without punctuation the most natural written Japanese at this boundary?',
    }
    for candidate in plan['candidates']:
        pos, text = candidate['offset'], plan['text']
        def tags(ts): return ' | '.join(t['surface'] + ':' + ','.join(t['pos'][:3]) for t in ts)
        state = (f'Japanese text: {text}\nLEFT: {text[:pos]}\nRIGHT: {text[pos:]}\n'
                 f'LEFT morphology: {tags(candidate["left_tokens"])}\nRIGHT morphology: {tags(candidate["right_tokens"])}')
        result.append([{'state': state, 'question': {'type': 'noul', 'instructions': instructions[key]}}
                       for key in MARKS])
    return result


def hybrid(plan, answers, threshold, margin):
    if len(answers) != len(plan['candidates']):
        raise ValueError('候補と応答の件数が不一致')
    marks = {int(i): m for i, m in plan['rule_marks'].items()}
    changed = 0
    for candidate, scores in zip(plan['candidates'], answers):
        options = sorted(candidate['permitted'], key=lambda k: scores[k], reverse=True)
        chosen = candidate['rule']
        if scores[options[0]] >= threshold and scores[options[0]] - scores[options[1]] > margin:
            chosen = options[0]
        changed += chosen != candidate['rule']
        marks.pop(candidate['offset'], None)
        if MARKS[chosen]: marks[candidate['offset']] = MARKS[chosen]
    result = apply_punctuation(plan['text'], marks)
    if split_punctuation(result)[0] != plan['text']:
        raise ValueError('本文が変化した')
    return result, changed
