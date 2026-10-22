"""Sudachiの候補だけを、他の位置はルール通りの完成文3候補でLayaへ渡す。"""
from sudachi_punctuation import MARKS, apply_punctuation


def choice_requests(plan):
    requests = []
    for candidate in plan['candidates']:
        base = {int(i): m for i, m in plan['rule_marks'].items()}
        base.pop(candidate['offset'], None)
        options = {}
        for choice, mark in MARKS.items():
            marks = dict(base)
            if mark: marks[candidate['offset']] = mark
            options[choice] = apply_punctuation(plan['text'], marks)
        requests.append({'state': '句読点だけが異なる三つの候補文を比較してください。',
                         'question': {'type': 'choice', 'instructions':
                             'Which candidate is the most natural written Japanese? Join greetings and self-introductions with a comma. Separate independent sentences with a period. Do not split words or predicates.',
                             'criteria': options}})
    return requests
