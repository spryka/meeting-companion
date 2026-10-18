"""Conservative phonetic replacements from a timestamped English donor transcript."""
import difflib
import re

STOP=set('а и но или либо да не ни в во на по за из от до с со к ко у о об обо при для без над под через что чтобы как это то же ли бы вот ну'.split())
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
def allowed(a,b,terms=()):
 # Latin-only donor words; punctuation is ignored, numbers must survive.
 return (all(re.fullmatch(r'[A-Za-z]+(?:[-’\'][A-Za-z]+)*[.,!?;:]?',s) for s in b.split())
  and not any(norm(w) in STOP for w in a.split())
  and re.findall(r'\d+',a)==re.findall(r'\d+',b)
  and len(phonetic(a)) >= 4 and len(phonetic(b)) >= 4
  and similarity(a,b) >= (0.65 if norm(b) in {norm(term) for term in terms} else 0.8))

def contiguous(words):
 return all(left['start'] <= right['start'] and right['start']-left['end'] <= 0.6
            for left,right in zip(words,words[1:]))

def cascade(g,p,terms=()):
 matcher=difflib.SequenceMatcher(None,[norm(x['text']) for x in g],[norm(x['text']) for x in p],autojunk=False)
 replacements={};rows=[]
 for op,ga,gz,pa,pz in matcher.get_opcodes():
  if op!='replace':continue
  options=[]
  for i in range(ga,gz):
   for n in (1,2):
    if i+n>gz:continue
    if any(w.get('speaker')!=g[i].get('speaker') for w in g[i:i+n]):continue
    if not contiguous(g[i:i+n]):continue
    a=' '.join(w['text'] for w in g[i:i+n])
    for j in range(pa,pz):
     if abs(g[i]['start']-p[j]['start'])>0.75:continue
     for m in (1,2):
      if j+m>pz:continue
      if not contiguous(p[j:j+m]):continue
      if abs(g[i+n-1]['end']-p[j+m-1]['end'])>0.75:continue
      if min(g[i+n-1]['end'],p[j+m-1]['end']) <= max(g[i]['start'],p[j]['start']):continue
      b=' '.join(w['text'] for w in p[j:j+m])
      if allowed(a,b,terms):options.append((similarity(a,b),i,n,j,m,a,b))
  alternatives={}
  for score,i,n,j,m,a,b in options:
   scores=alternatives.setdefault((i,n),{})
   scores[norm(b)]=max(score,scores.get(norm(b),0))
  usedg=set();usedp=set();selected=[]
  for score,i,n,j,m,a,b in sorted(options,reverse=True):
   if any(other >= score-0.1 for text,other in alternatives[i,n].items() if text!=norm(b)):continue
   if usedg.intersection(range(i,i+n)) or usedp.intersection(range(j,j+m)):continue
   if any((i-ii)*(j-jj)<0 for ii,jj in selected):continue
   selected.append((i,j));usedg.update(range(i,i+n));usedp.update(range(j,j+m))
   replacements[i]=(n,b)
   rows.append({'start':g[i]['start'],'end':g[i+n-1]['end'],'original':a,'proposed':b,
                'score':round(score,3),'donor_start':p[j]['start'],'donor_end':p[j+m-1]['end'],
                'reason':'dictionary' if norm(b) in {norm(term) for term in terms} else 'phonetic'})
 corrected=[];i=0
 while i<len(g):
  if i in replacements:
   n,b=replacements[i];corrected.append({**g[i],'end':g[i+n-1]['end'],'text':b});i+=n
  else:corrected.append(dict(g[i]));i+=1
 return corrected,sorted(rows,key=lambda r:r['start'])

