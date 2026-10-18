"""Correct timestamped terms using phonetic similarity and an optional glossary."""
import difflib
import re

STOP=set('а и но или либо да не ни в во на по за из от до с со к ко у о об обо при для без над под через что чтобы как это то же ли бы вот ну'.split())
STOP.update('я ты он она оно мы вы они меня мне мной мною тебя тебе тобой тобою его ему им ним него нем ее ей ею нее ней нас нам нами вас вам вами их ими них себя себе собой собою мой твой наш ваш свой'.split())
def norm(s):return re.sub(r'[^a-zа-яё0-9]','',s.lower()).replace('ё','е')
def phonetic(s):
 s=s.lower()
 for a,b in [('ch','ч'),('sh','ш'),('th','т'),('ph','ф'),('oo','у')]:s=s.replace(a,b)
 s=re.sub(r'c(?=[eiy])','с',s)
 s=s.translate(str.maketrans(dict(zip('abcdefghijklmnopqrstuvwxyz',['а','б','к','д','е','ф','г','х','и','дж','к','л','м','н','о','п','к','р','с','т','у','в','в','кс','и','з']))))
 s=s.translate(str.maketrans({'ё':'е','э':'е','й':'и','ы':'и','ь':'','ъ':''}))
 return re.sub(r'(.)\1+',r'\1',re.sub(r'[^а-я0-9]','',s))
def similarity(a,b):
 a,b=phonetic(a),phonetic(b)
 if not a or not b:return 0
 row=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  nxt=[i]
  for j,y in enumerate(b,1):nxt.append(min(nxt[-1]+1,row[j]+1,row[j-1]+(x!=y)))
  row=nxt
 return 1-row[-1]/max(len(a),len(b))
def allowed(a,b,known_term=False):
 # Latin-only donor words; punctuation is ignored, numbers must survive.
 # shortcut: phonetic similarity cannot distinguish homophones; context needs separate evaluation.
 return (all(re.fullmatch(r'[A-Za-z]+(?:[-’\'][A-Za-z]+)*[.,!?;:]?',s) for s in b.split())
  and re.findall(r'\d+',a)==re.findall(r'\d+',b)
  and len(phonetic(a)) >= 4 and len(phonetic(b)) >= 4
  and similarity(a,b) >= (0.65 if known_term else 0.8))

def contiguous(words):
 return all(left['start'] <= right['start'] and right['start']-left['end'] <= 0.6
            for left,right in zip(words,words[1:]))

def propose(g, p, terms=()):
    """Find alternatives without changing the GigaAM transcript."""
    known = {norm(term) for term in terms}
    matcher = difflib.SequenceMatcher(None, [norm(x['text']) for x in g],
                                    [norm(x['text']) for x in p], autojunk=False)
    rows = []
    for op, ga, gz, pa, pz in matcher.get_opcodes():
        if op != 'replace':
            continue
        for i in range(ga, gz):
            for n in (1, 2):
                source = g[i:i+n]
                if i+n > gz or not contiguous(source):
                    continue
                if any(w.get('speaker') != source[0].get('speaker') for w in source):
                    continue
                a = ' '.join(w['text'] for w in source)
                for j in range(pa, pz):
                    if abs(source[0]['start'] - p[j]['start']) > 0.75:
                        continue
                    for m in (1, 2):
                        donor = p[j:j+m]
                        if j+m > pz or not contiguous(donor):
                            continue
                        if abs(source[-1]['end'] - donor[-1]['end']) > 0.75:
                            continue
                        overlap = min(source[-1]['end'], donor[-1]['end']) - max(source[0]['start'], donor[0]['start'])
                        if overlap <= 0:
                            continue
                        b = ' '.join(w['text'] for w in donor)
                        if not allowed(a, b, norm(b) in known):
                            continue
                        union = max(source[-1]['end'], donor[-1]['end']) - min(source[0]['start'], donor[0]['start'])
                        protected = any(norm(w) in STOP for w in a.split())
                        rows.append(dict(start=source[0]['start'], end=source[-1]['end'],
                            original=a, proposed=b, score=round(similarity(a, b), 3),
                            donor_start=donor[0]['start'], donor_end=donor[-1]['end'],
                            source_indices=[i, i+n], donor_indices=[j, j+m],
                            time_overlap=round(overlap/union, 3), known_term=norm(b) in known,
                            applied=False, reason='protected_word' if protected else 'candidate'))
    return rows


def conflicts(a, b):
    return any(max(a[key][0], b[key][0]) < min(a[key][1], b[key][1])
               for key in ('source_indices', 'donor_indices'))


def cascade(g, p, terms=()):
    rows = propose(g, p, terms)
    candidates = [row for row in rows if row['reason'] == 'candidate']
    selected = []
    for row in sorted(candidates, key=lambda r: (r['time_overlap'], r['score']), reverse=True):
        # Glossary breaks close ties, but cannot overrule clearly better timing or sound.
        if any(other is not row and conflicts(row, other)
               and other['score'] >= row['score']-0.1
               and other['time_overlap'] >= row['time_overlap']-0.1
               and not (row['known_term'] and not other['known_term']
                        and other['score'] <= row['score']+0.1
                        and other['time_overlap'] <= row['time_overlap']+0.1)
               for other in candidates):
            row['reason'] = 'ambiguous'
            continue
        if any(conflicts(row, other) for other in selected):
            row['reason'] = 'conflict'
            continue
        i, _ = row['source_indices']
        j, _ = row['donor_indices']
        if any((i-other['source_indices'][0]) * (j-other['donor_indices'][0]) < 0 for other in selected):
            row['reason'] = 'crossing_alignment'
            continue
        row.update(applied=True, reason='dictionary' if row['known_term'] else 'phonetic')
        selected.append(row)
    replacements = {row['source_indices'][0]: row for row in selected}
    corrected = []
    i = 0
    while i < len(g):
        if i in replacements:
            row = replacements[i]
            corrected.append({**g[i], 'end': row['end'], 'text': row['proposed']})
            i = row['source_indices'][1]
        else:
            corrected.append(dict(g[i]))
            i += 1
    return corrected, sorted(rows, key=lambda r: r['start'])

