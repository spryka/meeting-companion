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
def allowed(a,b):
 # Latin-only donor words; punctuation is ignored, numbers must survive.
 return (all(re.fullmatch(r'[A-Za-z]+(?:[-’\'][A-Za-z]+)*[.,!?;:]?',s) for s in b.split())
  and not any(norm(w) in STOP for w in a.split())
  and re.findall(r'\d+',a)==re.findall(r'\d+',b)
  and similarity(a,b)>=0.4)

def cascade(g,p):
 matcher=difflib.SequenceMatcher(None,[norm(x['text']) for x in g],[norm(x['text']) for x in p],autojunk=False)
 replacements={};rows=[]
 for op,ga,gz,pa,pz in matcher.get_opcodes():
  if op!='replace':continue
  options=[]
  for i in range(ga,gz):
   for n in (1,2):
    if i+n>gz:continue
    if any(w.get('speaker')!=g[i].get('speaker') for w in g[i:i+n]):continue
    a=' '.join(w['text'] for w in g[i:i+n])
    for j in range(pa,pz):
     if abs(g[i]['start']-p[j]['start'])>2:continue
     for m in (1,2):
      if j+m>pz:continue
      b=' '.join(w['text'] for w in p[j:j+m])
      if allowed(a,b):options.append((similarity(a,b),i,n,j,m,a,b))
  usedg=set();usedp=set();selected=[]
  for score,i,n,j,m,a,b in sorted(options,reverse=True):
   if usedg.intersection(range(i,i+n)) or usedp.intersection(range(j,j+m)):continue
   if any((i-ii)*(j-jj)<0 for ii,jj in selected):continue
   selected.append((i,j));usedg.update(range(i,i+n));usedp.update(range(j,j+m))
   replacements[i]=(n,b)
   rows.append({'start':g[i]['start'],'end':g[i+n-1]['end'],'original':a,'proposed':b,'score':round(score,3)})
 corrected=[];i=0
 while i<len(g):
  if i in replacements:
   n,b=replacements[i];corrected.append({**g[i],'end':g[i+n-1]['end'],'text':b});i+=n
  else:corrected.append(dict(g[i]));i+=1
 return corrected,sorted(rows,key=lambda r:r['start'])

