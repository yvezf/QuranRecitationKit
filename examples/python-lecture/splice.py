"""Opt-in example: propose canonical replacements in WORD-timestamped ASR.

Never pass whole-paragraph timestamps; review proposals before applying them.
Neither ambiguous quotes nor text-only candidates are replaced.
"""
def propose_replacements(words, quotes):
    replacements=[]
    for q in quotes:
        if not q.get('verified') or q.get('ambiguous') or not q.get('text_uthmani'):continue
        indices=[i for i,w in enumerate(words) if q['start_seconds'] <= (w['start']+w['end'])/2 < q['end_seconds']]
        if not indices:continue
        replacements.append({'word_from':indices[0],'word_to':indices[-1]+1,'original':' '.join(w['text'] for w in words[indices[0]:indices[-1]+1]),'replacement':q['text_uthmani'],'reference':q['reference'],'start':q['start_seconds'],'end':q['end_seconds'],'requires_review':True})
    return replacements
