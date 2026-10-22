"""3〜5個の局所判定を数値で組み合わせる。プロンプトと選択規則の共通部。"""

import json
import math
from pathlib import Path

from punctuation_eval import ROOT, PUNCTUATION, ORDERS, make_request, render, validate_cases

LABELS = list(PUNCTUATION)
PROTOCOLS = ['factors_en', 'factors_ja', 'fluency_en', 'fluency_ja',
             'pairwise_en', 'pairwise_ja', 'direct',
             'specific_en', 'specific_ja', 'fewshot_en', 'fewshot_ja']
PAIRS = [('comma', 'period'), ('period', 'none'), ('none', 'comma')]
FACTORS = {
    'en': [
        'The left and right parts belong to one word, name, number, or grammatical phrase '
        '(including a quotation followed by its particle, or a verb followed by its auxiliary). '
        'Inserting punctuation between them would break that unit.',
        'The left part is a complete statement and the right part starts a separate sentence. '
        'A Japanese full stop is needed between them.',
        'The boundary separates clauses or items within one sentence, or connects a greeting '
        'to a self-introduction. A Japanese comma is appropriate here.',
    ],
    'ja': [
        '左右は一つの単語、固有名詞、数値、引用と助詞、または補助動詞を含む一つの述語を構成している。間に句読点を入れるとそのまとまりを壊す。',
        '左は一つの文として完結し、右から別の独立した文が始まっている。間に句点「。」が必要である。',
        '境界は一つの文の中の節や列挙項目の区切り、または挨拶と名乗りの間であり、読点「、」が自然である。',
    ],
}
FLUENCY = {
    'en': 'Is the punctuation grammatically appropriate in this Japanese text? '
          'Punctuation must not split words, names, numbers or verb phrases. '
          'A full stop should separate complete sentences.',
    'ja': 'この日本語の句読点は文法的に適切ですか。単語、固有名詞、数値、述語の途中を分断せず、句点は完結した文を区切っている必要があります。',
}
PAIRWISE = {
    'en': 'Which text has more natural Japanese punctuation? Keep words and verb phrases intact. '
          'Use a comma for a greeting plus self-introduction, and a full stop between separate sentences.',
    'ja': 'どちらの句読点がより自然ですか。単語や述語は分断せず、挨拶と名乗りは読点でつなぎ、独立した文は句点で区切ります。',
}
SPECIFIC = {
    'en': [
        'Does the RIGHT part grammatically complete the verb phrase started in LEFT, '
        'rather than start a separate action? For example an auxiliary verb after a main verb.',
        'Does the boundary split one noun phrase, proper name, compound word, numeric expression, '
        'or a quotation and its following grammatical particle?',
        'Is LEFT a complete declarative sentence with its own finite predicate? '
        'A greeting, acknowledgment, listed noun, or conditional clause is not a declarative sentence.',
        'Are LEFT and RIGHT consecutive items of a list or an intentional repetition?',
        'Does LEFT act as a greeting, apology, or short acknowledgment that introduces RIGHT?',
    ],
    'ja': [
        '右は新しい行動を始めるのではなく、左から続く述語を補助動詞などで文法的に完成させていますか。',
        '境界は一つの名詞句、固有名詞、複合語、数値表現、または引用とその助詞の内部ですか。',
        '左は終止形の述語を持ち、一つの独立した説明文として完結していますか。挨拶、相づち、列挙の名詞、条件節は説明文には含めません。',
        '左右は並べて挙げる項目同士、または意図的に反復する表現ですか。',
        '左は右の発話を導く挨拶、謝罪、または短い相づちですか。',
    ],
}
EXAMPLES = (
    'Punctuation examples (LEFT | RIGHT => punctuation):\n'
    '茶 | 碗を洗う => none\n'
    '案内をして | います => none\n'
    '犬 | 猫がいます => comma\n'
    '忙しいので | 後にします => comma\n'
    'どうも | 村上と申します => comma\n'
    '確認済みです | 問題ありません => period\n'
    'Below is the TARGET. Answer only about this target:\n'
)


def split_cases():
    original = json.loads((ROOT / 'tools/laya-eval/cases.json').read_text())['cases']
    new = json.loads((ROOT / 'tools/punctuation-ensemble/new-cases.json').read_text())['cases']
    validate_cases(original + new)
    return {'development': [c for c in original + new if c['split'] == 'development'],
            'original': original, 'holdout': [c for c in new if c['split'] == 'evaluation']}


def views(case, protocol):
    def noul(state, instruction):
        return {'state': state, 'question': {'type': 'noul', 'instructions': instruction}}

    state = f'Left: {case["left"]}\nRight: {case["right"]}'
    if protocol == 'direct':
        result = []
        for name in ('ja', 'en', 'candidate_ja', 'candidate_en'):
            text, questions = make_request(case, name, ORDERS[0])
            result.append({'state': text, 'question': questions['punctuation']})
        result.append({'state': state, 'question': {'type': 'choice',
            'instructions': 'How are the left and right parts related grammatically?',
            'criteria': {'none': 'Parts of one word, name, number or verb phrase that must stay together',
                         'comma': 'Clauses or list items in one sentence, or a greeting and self-introduction',
                         'period': 'Two separate complete sentences'}}})
        return result
    kind, language = protocol.rsplit('_', 1)
    if kind in ('specific', 'fewshot'):
        target = (EXAMPLES if kind == 'fewshot' else '') + state
        return [noul(target, instruction) for instruction in SPECIFIC[language]]
    guards = [noul(state, instruction) for instruction in FACTORS[language][:2]]
    if kind == 'factors':
        other = 'ja' if language == 'en' else 'en'
        return [noul(state, instruction) for instruction in FACTORS[language]] + [
            noul(state, instruction) for instruction in FACTORS[other][:2]]
    if kind == 'fluency':
        return [noul(render(case, label), FLUENCY[language]) for label in LABELS] + guards
    if kind == 'pairwise':
        return [{'state': '句読点だけが異なる候補を比較してください。', 'question': {
            'type': 'choice', 'instructions': PAIRWISE[language],
            'criteria': {'a': render(case, left), 'b': render(case, right)}}}
            for left, right in PAIRS] + guards
    raise ValueError('未知の質問方式')


def logit(p):
    p = min(1 - 1e-5, max(1e-5, p))
    return math.log(p / (1 - p))


def features(row, count):
    result = []
    for probabilities in row['answers'][:count]:
        if set(probabilities) == set(LABELS):
            logs = [math.log(max(1e-5, probabilities[k])) for k in LABELS]
            result.extend(p - sum(logs) / len(logs) for p in logs)
        else:
            result.append(logit(probabilities.get('true', probabilities.get('a'))))
    return result


def normalize(scores):
    positive = [max(0, float(s)) for s in scores]
    total = sum(positive)
    return [s / total for s in positive] if total else [1 / 3] * 3


def combine(row, count):
    answers, protocol = row['answers'], row['protocol']
    if protocol == 'direct':
        return [sum(p[k] for p in answers[:count]) / count for k in LABELS]
    if protocol.startswith(('specific', 'fewshot')):
        auxiliary, noun, sentence = [a['true'] for a in answers[:3]]
        unit = max(auxiliary, noun)
        comma = max(a['true'] for a in answers[3:5]) if count == 5 else 0.
        return normalize([(1-unit) * max(1-sentence, comma),
                          (1-unit) * sentence * (1-comma), unit])
    if protocol.startswith('factors'):
        unit, sentence, comma = [a['true'] for a in answers[:3]]
        if count == 5:
            unit = (unit + answers[3]['true']) / 2
            sentence = (sentence + answers[4]['true']) / 2
        return normalize([(1-unit) * (1-sentence) * comma,
                          (1-unit) * sentence * (1-comma), unit * (1-sentence)])
    if protocol.startswith('fluency'):
        scores = [a['true'] for a in answers[:3]]
    else:
        scores = [0., 0., 0.]
        for probabilities, (a, b) in zip(answers[:3], PAIRS):
            scores[LABELS.index(a)] += probabilities['a'] / 2
            scores[LABELS.index(b)] += probabilities['b'] / 2
    if count == 5:
        unit, sentence = answers[3]['true'], answers[4]['true']
        scores = [scores[0] * (1-unit) * (1-sentence),
                  scores[1] * (1-unit) * sentence, scores[2] * unit]
    return normalize(scores)


def fit_ridge(vectors, labels, alpha):
    import numpy as np
    x = np.asarray(vectors, dtype=float)
    mean, std = x.mean(axis=0), x.std(axis=0)
    std = np.maximum(std, .05)
    z = (x - mean) / std
    y = np.eye(3)[[LABELS.index(label) for label in labels]]
    intercept = y.mean(axis=0)
    weights = np.linalg.solve(z.T @ z + alpha * np.eye(z.shape[1]), z.T @ (y-intercept))
    return {'mean': mean.tolist(), 'std': std.tolist(), 'weights': weights.tolist(),
            'intercept': intercept.tolist(), 'alpha': alpha}


def predict_ridge(model, vector):
    scores = list(model['intercept'])
    for value, mean, std, weights in zip(vector, model['mean'], model['std'], model['weights']):
        for i in range(3):
            scores[i] += (value-mean) / std * weights[i]
    return normalize(scores)


def choose(case, scores, margin):
    ranked = sorted(range(3), key=lambda i: scores[i], reverse=True)
    if not case['right'].strip() or scores[ranked[0]] - scores[ranked[1]] <= margin + 1e-12:
        return case['original']
    return LABELS[ranked[0]]
