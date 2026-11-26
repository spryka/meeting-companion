
'use strict';
(() => {
const scenario=new URLSearchParams(location.search).get('scenario')||'voices';
const extraNames=['Николай Белов','Павел Лазарев','Елена Тихонова','Софья Миронова','Артём Горин','Ольга Крылова','Виктор Зорин','Дарья Мельникова','Роман Савин','Вера Зимина','Кирилл Осипов','Нина Громова','Максим Рощин','Алина Фомина','Степан Руднев','Лидия Власова','Глеб Титов','Ксения Егорова','Лев Нестеров','Полина Ершова','Тимур Грачёв','Алиса Данилова'];
const profileSeed=()=>[
 {id:'person-anna',name:'Анна Лебедева',email:'anna.lebedeva@north.example',status:'Готов',available:true,revision:0,manualSources:4},
 {id:'person-ilya',name:'Илья Соколов',email:'ilya.sokolov@north.example',status:'Готов',available:true,revision:0,manualSources:3},
 {id:'person-maria',name:'Мария Орлова',email:'maria.orlova@north.example',status:'Готов',available:true,revision:0,manualSources:2},
 ...extraNames.map((name,i)=>({id:'person-extra-'+i,name:i===0?'Анна Лебедева':name,note:i===0?'Подрядчик':'',status:i===19?'Недостаточно речи':i===20?'Нужно обновить профиль':i===21?'Не удалось обновить':'Готов',available:i!==19&&i!==20,revision:0,manualSources:i===19?0:2+i%4}))
];
const vi={enabled:scenario!=='empty',model:scenario!=='empty',preparing:false,profiles:scenario==='empty'?[]:profileSeed(),review:null,group:0,turn:null,editorRecord:null,pane:'detail',drafts:new Map(),learnedVoices:new Map(),deleteTarget:null,resetTarget:null,person:null,profileQuery:'',onlyUnknown:false,transcriptScroll:0};
const fictionalCalendar=[
 {name:'Илья Соколов',email:'ilya.sokolov@north.example'},
 {name:'Мария Орлова',email:'maria.orlova@north.example'},
 {name:'Денис Ветров',email:'denis.vetrov@north.example'}
];
paths['speaker-auto']='<rect x="5" y="6" width="14" height="13" rx="3"/><path d="M12 3v3M2 10v5M22 10v5M9 15h6"/><circle cx="9" cy="11" r=".75"/><circle cx="15" cy="11" r=".75"/>';
paths['speaker-manual']=paths.edit;
paths['chevron-down']='<path d="m6 9 6 6 6-6"/>';
const groupTexts=[
 ['Сверим поведение первого экрана. После встречи результат должен быть доступен сразу.','Знакомых участников больше не нужно подписывать заново после каждого созвона.','Договорились, начнём с этого сценария.'],
 ['Предлагаю оставить библиотеку слева, а текст встречи — справа.','На длинных встречах нужен быстрый переход к нужной реплике.','В календаре меня нет, я присоединилась по общей ссылке.'],
 ['Привет, я Денис. Сегодня впервые присоединился к вашей встрече.','Добавлю предложение по порядку действий.','Вернусь с примерами на следующей встрече.'],
 ['Здесь мнения совпали. Давайте теперь уточним порядок действий.','Первым действием будет просмотр готового результата.','Если приложение ошиблось с именем, его можно исправить прямо в тексте.'],
 ['Автоматические имена не должны сами становиться обучающими образцами.','Здесь имя уже было исправлено вручную. Сохраните эту правку.','Для обучения подойдут только вручную размеченные фрагменты.'],
 ['Удобно, что один человек может быть узнан на разных дорожках.','Давайте оставим подготовку модели отдельным явным действием.','А сброс обучения одного человека не должен затрагивать остальных.'],
 ['Меня зовут Олег, мы ещё не работали вместе.','Я повторю предложение после проверки фрагмента.','На следующей встрече уточним детали.']
];
const expected=['person-anna','person-anna',null,'person-ilya','person-maria','person-extra-0',null];
const demoRows=groupTexts.flatMap((texts,s)=>texts.map((text,j)=>({
 t:s*220+j*57,s,source:s===0||s===5?'mic':'system',text,voiceSignature:s===0||s===1?'sample-anna':s===4&&j===1?'sample-ilya':'sample-voice-'+s,
 speakerName:s===4&&j===1?'Илья Соколов':undefined,
 identity:s===4&&j===1?'person-ilya':null,nameOrigin:s===4&&j===1?'manual':undefined,
 expectedProfileId:scenario==='all-known'?(expected[s]||'person-extra-1'):expected[s],
 voiceCase:expected[s]||scenario==='all-known'?'found':'unknown',profileUpdateError:s===3
})));
if(scenario==='uncertain')demoRows.forEach(t=>{if(t.s===2)t.voiceCase='ambiguous';if(t.s===6)t.voiceCase='overlap';});
const failureCases={'little-speech':'short','audio-unavailable':'unavailable','recognition-error':'error'};
if(failureCases[scenario])demoRows.forEach(t=>{if(t.s===2||t.s===6)t.voiceCase=failureCases[scenario];});
records.unshift({id:'voice-demo',title:'Обсуждение продукта',day:'Сегодня',date:'18 ноября 2026',time:'11:32',duration:1500,status:'ready',voiceAuto:true,rows:demoRows});
records.splice(1,0,{id:'voice-next',title:'Следующая встреча · знакомые участники',day:'Сегодня',date:'18 ноября 2026',time:'12:30',duration:780,status:'ready',voiceAuto:true,rows:[0,3,4].flatMap((group,k)=>demoRows.filter(t=>t.s===group).slice(0,2).map((t,j)=>({...t,t:k*220+j*57,speakerName:undefined,identity:null,nameOrigin:undefined,text:['Обсудим следующий шаг и распределим работу.','Хорошо, к следующей встрече подготовим результат.'][j]})))});
state.selected='voice-demo';state.position=0;state.playing=false;
if(scenario==='off')vi.enabled=false;
if(scenario==='model')vi.model=false;
if(scenario==='one-profile')vi.profiles=vi.profiles.slice(0,1);
if(scenario==='stale'){vi.profiles[0].status='Нужно обновить профиль';vi.profiles[0].available=false;}
if(scenario==='update-error')vi.profiles[0].status='Не удалось обновить';
if(scenario==='long-name')vi.profiles[0].name='Анна Александра Лебедева Константинопольская';
const normalized=name=>name.normalize('NFC').trim().toLocaleLowerCase('ru');
const contact=p=>p?.email||p?.note||'';
const personLabel=p=>p.name+(contact(p)?' · '+contact(p):'');
const groupCount=n=>n+' '+(n%100>=11&&n%100<=14?'реплик':n%10===1?'реплика':n%10>=2&&n%10<=4?'реплики':'реплик');
const sourceLabel=t=>t.source==='mic'?'Микрофон':'Системный звук';
const groupKey=t=>String(t.s)+':'+(t.source||'system');
const rowLabel=t=>'Speaker '+(Number(t.s)+1);
speakerLabel=t=>t.speakerName||rowLabel(t);
function groups(r=selected()){
 if(!r)return [];
 const result=[];
 r.rows.forEach((t,index)=>{let g=result.find(g=>g.key===groupKey(t));if(!g){g={key:groupKey(t),label:rowLabel(t),source:sourceLabel(t),indices:[]};result.push(g);}g.indices.push(index);});
 return result;
}
function activeGroup(){return groups().find(g=>g.key===vi.group)||groups()[0];}
function draftKey(r,index){return r.id+':'+index;}
function createEditorDraft(row,index,profiles){
 return {name:row.speakerName||'',identity:profiles.some(p=>p.id===row.identity)?row.identity:'',turn:index,scope:'group',overwrite:false};
}
function getEditorDraft(r,index){
 const key=draftKey(r,index);
 if(!vi.drafts.has(key))vi.drafts.set(key,createEditorDraft(r.rows[index],index,vi.profiles));
 return vi.drafts.get(key);
}
function groupDraft(){return getEditorDraft(selected(),vi.turn);}
function matchingProfiles(name){return vi.profiles.filter(p=>normalized(p.name)===normalized(name));}
function calendarPeople(r=selected()){
 const used=new Set(r.rows.map(t=>t.identity));
 return fictionalCalendar.filter(entry=>!vi.profiles.some(p=>p.email===entry.email&&used.has(p.id)));
}
const viButton=(action,label,cls='btn',extra='')=>'<button type="button" class="'+cls+'" data-vi="'+action+'" '+extra+'>'+label+'</button>';
function identityMarkup(d){
 const matches=matchingProfiles(d.name);
 const p=vi.profiles.find(p=>p.id===d.identity);
 if(p&&contact(p))return '<p class="vi-muted">'+esc(contact(p))+'</p>';
 return d.identity==='new'?'<div class="vi-contact-fields vi-identity"><label for="viNewEmail">Email</label><input type="email" id="viNewEmail" maxlength="160" value="'+esc(d.email||'')+'"><label for="viNewNote">Подпись</label><input type="text" id="viNewNote" maxlength="80" placeholder="Например, компания" value="'+esc(d.note||'')+'"><small>'+(matches.length?'Укажите email или подпись, чтобы отличить одноимённых людей.':'Email и подпись необязательны.')+'</small></div>':'';
}
function identityError(d){
 const matches=matchingProfiles(d.name);
 if(!d.identity&&d.name.includes('@'))return 'Выберите человека из результатов поиска или введите имя.';
 if(d.identity!=='new')return matches.length&&!matches.some(p=>p.id===d.identity)?'Выберите человека или добавьте нового.':'';
 const email=(d.email||'').trim(),note=(d.note||'').trim();
 if(email&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))return 'Проверьте адрес email.';
 if(email&&vi.profiles.some(p=>normalized(p.email||'')===normalized(email)))return 'Человек с таким email уже есть. Выберите его в списке.';
 if(matches.length&&!email&&(!note||matches.some(p=>normalized(p.note||'')===normalized(note))))return 'Укажите email или отличающую подпись.';
 return '';
}
function identityValid(d){return !identityError(d);}
function validName(name){return !!name.trim()&&name.trim().length<=120&&!/[\u0000-\u001f\u007f]/.test(name);}
function selectedTargets(r,indices,d){
 if(!indices.includes(d.turn))return [];
 let targets=indices;
 if(d.scope==='one'&&d.turn!==null)targets=indices.filter(i=>i===d.turn);
 if(d.scope==='remaining'&&d.turn!==null)targets=indices.filter(i=>i>=d.turn);
 return targets.filter(i=>!r.rows[i].speakerName||r.rows[i].nameOrigin==='auto'||d.overwrite||d.scope==='one');
}
function changesFor(r,indices,d){
 return selectedTargets(r,indices,d).filter(i=>r.rows[i].speakerName!==d.name.trim()||(d.identity&&d.identity!=='new'&&r.rows[i].identity!==d.identity)||d.identity==='new');
}
function hintMarkup(r,index){
 const t=r.rows[index];
 const reason=refusal[t.voiceCase]||{title:'Незнакомый голос',detail:'Назначьте имя один раз. После подготовки профиля приложение узнает человека в следующих встречах.'};
 return contextHelp('voiceRecognitionHelp','Почему у реплики нет имени?','<strong>'+esc(reason.title)+'</strong><p>'+esc(reason.detail)+'</p>');
}
function refreshProfileViews(){renderProfiles();if(vi.review===state.selected&&$('viGroupIdentity')){renderGroupIdentity();updateGroupPreview();}}
function profileHelp(p){
 if(p.status==='Обучение сброшено')return 'Образцы удалены. Чтобы обучить профиль заново, назначьте или исправьте имя в транскрипте.';
 if(p.status==='Недостаточно речи')return 'Назначьте имя в следующих встречах. Подбор подходящих фрагментов автоматический.';
 if(p.status==='Не удалось обновить')return 'Не удалось обновить. Ранее сохранённый профиль доступен.';
 if(p.status==='Нужно обновить профиль')return 'Назначьте или исправьте имя в транскрипте, чтобы обновить профиль.';
 if(p.status==='Обновляется')return p.available?'Уточняем профиль. Ранее сохранённый профиль доступен.':'Подбираем подходящие фрагменты из ручной разметки.';
 return 'Знакомый голос будет автоматически подписан при обработке новой записи.';
}
function renderProfiles(){
 if(!$('viProfiles'))return;
 $('viEnabled').checked=vi.enabled;
 $('viPause').hidden=vi.enabled;
 $('viRecognitionHint').hidden=!vi.enabled;
 $('viModelPrompt').hidden=!vi.enabled||vi.model;
 $('viModelState').textContent=vi.preparing?'Идёт подготовка модели…':'Для распознавания нужна локальная модель.';
 $('viPrepare').disabled=vi.preparing;
 $('viDeleteAll').disabled=!vi.profiles.length;
 $('viDirectoryOptions').disabled=!vi.profiles.length;
 renderPeople();
}

const sourceCountForm=new Intl.PluralRules('ru');
function personRow(p,showContact){
 const open=vi.person===p.id;
 const id=esc(p.id),name=esc(p.name);
 const initials=p.name.trim().split(/\s+/u).slice(0,2).map(part=>Array.from(part)[0]).join('');
 const detailId='vi-detail-'+id;
 const detailContact=contact(p)&&(open||showContact)?'<small>'+esc(contact(p))+'</small>':'';
 const updating=p.status==='Обновляется';
 const status=p.status==='Готов'?'':'<span class="vi-row-status'+(updating?' is-updating':'')+'">'+esc(p.status)+'</span>';
 const row='<button type="button" class="vi-directory-row" id="vi-row-'+id+'" data-vi="person" data-person="'+id+'" aria-expanded="'+open+'" aria-controls="'+detailId+'">'
  +'<span class="vi-monogram" aria-hidden="true">'+esc(initials)+'</span>'
  +'<span class="vi-person-label"><strong>'+name+'</strong>'+detailContact+'</span>'+status
  +'<span class="vi-chevron">'+icon('chevron-down')+'</span></button>';
 let content='';
 if(open){
  const count=p.manualSources||0;
  const form={one:'встреча',few:'встречи',many:'встреч',other:'встречи'}[sourceCountForm.select(count)];
  const ready=p.status==='Готов'?'<span class="vi-ready">'+icon('check')+'Голос знаком</span><span aria-hidden="true">·</span>':'';
  const resetDisabled=p.status==='Обучение сброшено'?'disabled':'';
  content='<div class="vi-person-meta">'+ready+'<span>'+count+' '+form+' с ручной разметкой</span></div>'
   +(p.status==='Готов'?'':'<p>'+esc(profileHelp(p))+'</p>')
   +'<div class="vi-inline-actions">'+viButton('reset-person','Сбросить обучение…','btn','id="viResetPerson" data-person="'+id+'" '+resetDisabled)
   +'<button type="button" class="icon-button vi-menu-trigger" id="viPersonOptionsButton" popovertarget="viProfileMenu" aria-label="Другие действия с профилем '+name+'">'+icon('more')+'</button>'
   +'<div id="viProfileMenu" class="context-help vi-directory-menu" popover>'+viButton('delete-person','Удалить человека…','','data-person="'+id+'"')+'</div></div>';
 }
 return '<li class="vi-directory-item'+(open?' is-open':'')+'">'+row+'<div class="vi-person-expanded" id="'+detailId+'"'+(open?'':' hidden')+'>'+content+'</div></li>';
}

function renderPeople(){
 const list=$('viProfiles');
 const focusId=list.contains(document.activeElement)?document.activeElement.id:null;
 const query=normalized(vi.profileQuery);
 const filtered=vi.profiles.filter(p=>normalized(personLabel(p)).includes(query))
  .sort((a,b)=>a.name.localeCompare(b.name,'ru')||contact(a).localeCompare(contact(b),'ru'));
 if(!filtered.some(p=>p.id===vi.person))vi.person=null;
 const counts=new Map();
 for(const p of vi.profiles){
  const name=normalized(p.name);
  counts.set(name,(counts.get(name)||0)+1);
 }
 $('viPeopleCount').textContent=query?filtered.length+' из '+vi.profiles.length:String(vi.profiles.length);
 if(filtered.length){
  list.innerHTML=filtered.map(p=>personRow(p,counts.get(normalized(p.name))>1||(query&&normalized(contact(p)).includes(query)))).join('');
 }else{
  const title=vi.profiles.length?'Никого не нашли':'Пока нет знакомых голосов';
  const hint=vi.profiles.length?'Попробуйте другое имя, email или подпись.':'Назначьте имя говорящему в транскрипте.';
  list.innerHTML='<li class="vi-empty"><strong>'+title+'</strong><p>'+hint+'</p></li>';
 }
 if(focusId){
  const target=$(focusId);
  (target&&!target.disabled?target:$('vi-row-'+vi.person)||$('viPeopleSearch')).focus({preventScroll:true});
 }
}

function preparation(){
 if(vi.preparing||vi.model)return;
 vi.preparing=true;renderProfiles();
 setTimeout(()=>{
  vi.preparing=false;vi.model=true;
  const returnFocus=$('viPrepare')===document.activeElement;
  renderProfiles();
  if(returnFocus)$('viEnabled').focus({preventScroll:true});
  toast('Модель подготовлена в макете.');
 },1400);
}
function openVoiceSettings(){
 actions.settings();settingsTab('voices');
 requestAnimationFrame(()=>$('viVoiceTitle').focus({preventScroll:true}));
}
function profileAfterManual(name,identity,rows){
 if(!vi.enabled)return 'Имя сохранено. Автоматическое определение и обучение выключены.';
 if(!vi.model)return 'Имя сохранено. Подготовьте модель в настройках, чтобы уточнять профили.';
 let p=identity&&identity!=='new'?vi.profiles.find(p=>p.id===identity):null;
 if(!p){p={id:'person-'+crypto.randomUUID(),name,status:'Недостаточно речи',available:false,revision:0};vi.profiles.push(p);}
 const clean=rows.filter(t=>t.nameOrigin==='manual'&&!['overlap','short','unavailable','error'].includes(t.voiceCase));
 if(!clean.length){if(!p.available)p.status='Недостаточно речи';renderProfiles();return 'Имя сохранено. Для профиля недостаточно речи; назначьте имя в следующих встречах.';}
 p.status='Обновляется';p.revision++;const revision=p.revision;
 const sourceMeeting=selected()?.id;
 renderProfiles();
 setTimeout(()=>{
  if(!vi.enabled||!vi.profiles.includes(p)||p.revision!==revision)return;
  if(rows.some(t=>t.profileUpdateError)&&p.available)p.status='Не удалось обновить';
  else{p.status='Готов';p.available=true;clean.forEach(t=>{if(t.voiceSignature)vi.learnedVoices.set(t.voiceSignature,p.id);});p.sourceMeetings??=[];if(!p.sourceMeetings.includes(sourceMeeting)){p.sourceMeetings.push(sourceMeeting);p.manualSources=(p.manualSources||0)+1;}}
  renderProfiles();const message=p.status==='Не удалось обновить'?'Не удалось обновить. Ранее сохранённый профиль доступен. Имя сохранено.':'Голосовой профиль обновлён';
  toast(message);
 },1700);
 return 'Имя сохранено. Подходящие фрагменты добавятся автоматически.';
}
function commitName(r,indices,d){
 if(!validName(d.name)||!identityValid(d))return {ok:false};
 const changed=changesFor(r,indices,d);if(!changed.length)return {ok:false};
 const name=d.name.trim();preserveOriginal(r);
 let identity=d.identity;
 if(identity==='new'||!vi.profiles.some(p=>p.id===identity)){
  identity='person-'+crypto.randomUUID();
  vi.profiles.push({id:identity,name,email:d.email?.trim(),note:d.note?.trim(),status:'Недостаточно речи',available:false,revision:0});
 }
 for(const i of changed){
  const t=r.rows[i],key=draftKey(r,i),draft=vi.drafts.get(key);
  const previous=createEditorDraft(t,i,vi.profiles);
  if(draft&&draft.name===previous.name&&draft.identity===previous.identity&&!draft.overwrite)vi.drafts.delete(key);
  t.speakerName=name;t.identity=identity;t.nameOrigin='manual';
 }
 const message=profileAfterManual(name,identity,changed.map(i=>r.rows[i]));
 renderProfiles();return {ok:true,message,changed};
}
const refusal={
 ambiguous:{title:'Голос не определён уверенно',detail:'Близки несколько профилей. Назначьте имя вручную.'},
 short:{title:'Мало чистой речи',detail:'Недостаточно материала для определения. Назначьте имя вручную.'},
 overlap:{title:'Наложение голосов',detail:'В этом фрагменте говорят одновременно. Проверьте имя вручную.'},
 unavailable:{title:'Аудио недоступно',detail:'Не удалось определить голос. Текст и ручное назначение доступны.'},
 error:{title:'Не удалось определить голос',detail:'Обработка имён завершилась с ошибкой. Текст сохранён, имя можно назначить вручную.'},
 reset:{title:'Обучение этого голоса сброшено',detail:'Для нового профиля нужно ручное назначение. Старые образцы не возвращаются автоматически.'},
 disabled:{title:'Автоматическое определение выключено',detail:'Настройки → Голоса. Сохранённые имена не изменены.'},
 model:{title:'Модель голосов не подготовлена',detail:'Подготовьте её в разделе «Голоса». Основная транскрибация доступна.'}
};
// shortcut: matches are synthetic fixture facts; replace this function with audio matching in the native app.
function assignKnownRows(rows,profiles,enabled,model){
 const byId=new Map(profiles.filter(p=>p.available).map(p=>[p.id,p]));
 rows.forEach(t=>{
  if(t.speakerName)return;
  if(!enabled){t.voiceCase='disabled';return;}
  if(!model){t.voiceCase='model';return;}
  if(t.voiceCase!=='found')return;
  const p=byId.get(t.expectedProfileId);
  if(p){t.speakerName=p.name;t.identity=p.id;t.nameOrigin='auto';}
  else t.voiceCase=profiles.some(p=>p.id===t.expectedProfileId&&p.status==='Обучение сброшено')?'reset':'unknown';
 });
}
function autoIdentifyRecord(r){
 if(!r?.voiceAuto||r.status!=='ready'||r.recognitionProcessed)return;
 r.rows.forEach(t=>{if(vi.learnedVoices.has(t.voiceSignature)&&['unknown','found','reset'].includes(t.voiceCase)){t.expectedProfileId=vi.learnedVoices.get(t.voiceSignature);t.voiceCase='found';}});
 assignKnownRows(r.rows,vi.profiles,vi.enabled,vi.model);r.recognitionProcessed=true;
}
function resetProfileLearning(p){
 p.available=false;p.status='Обучение сброшено';p.revision++;p.manualSources=0;p.sourceMeetings=[];
}
function confirmReset(person){
 const p=vi.profiles.find(p=>p.id===person);if(!p)return;
 vi.resetTarget=person;$('viResetName').textContent=personLabel(p);
 openDialog('viResetDialog');$('viResetCancel').focus();
}
function resetLearning(){
 const p=vi.profiles.find(p=>p.id===vi.resetTarget);if(!p)return;
 resetProfileLearning(p);refreshProfileViews();closeDialog('viResetDialog');
 requestAnimationFrame(()=>$('vi-row-'+p.id)?.focus({preventScroll:true}));
 toast('Обучение '+p.name+' сброшено. Записи и имена сохранены.');
}
function renderGroupIdentity(){
 $('viGroupIdentity').innerHTML=identityMarkup(groupDraft());
}
function showPersonOptions(open,filter=true){
 const list=$('viPersonOptions');if(!list)return;
 list.hidden=!open;$('viPeopleToggle').setAttribute('aria-expanded',String(open));
 if(!open)return;
 const d=groupDraft(),query=filter?normalized(d.name):'';
 const people=vi.profiles.filter(p=>normalized(personLabel(p)).includes(query)).sort((a,b)=>a.name.localeCompare(b.name,'ru'));
 const calendar=calendarPeople().filter(p=>!vi.profiles.some(person=>person.email===p.email)&&normalized(personLabel(p)).includes(query));
 const rows=people.map(p=>viButton('choose-person','<strong>'+esc(p.name)+'</strong>'+(contact(p)?'<small>'+esc(contact(p))+'</small>':''),'vi-person-option','data-person="'+esc(p.id)+'"'));
 rows.unshift(...calendar.map(p=>viButton('calendar-name','<strong>'+esc(p.name)+'</strong><small>'+esc(p.email)+' · Календарь</small>','vi-person-option','data-email="'+esc(p.email)+'"')));
 if(validName(d.name)&&!d.identity&&!d.name.includes('@'))rows.push(viButton('new-person',matchingProfiles(d.name).length?'Другой человек с этим именем':'Добавить «'+esc(d.name.trim())+'»','vi-person-option'));
 list.innerHTML=rows.join('')||'<p class="vi-muted">Никого не нашли.</p>';
}
const scopeLabels={group:'Применить ко всем',one:'Применить к реплике',remaining:'Применить к этой и следующим'};
function updateGroupPreview(){
 if(vi.review!==state.selected||!$('viAssign'))return;
 const d=groupDraft(),r=selected(),g=activeGroup();
 const valid=validName(d.name)&&identityValid(d);
 const unprotected=changesFor(r,g.indices,{...d,scope:'group',overwrite:true});
 const protectedCount=d.scope==='one'?0:unprotected.filter(i=>(d.scope!=='remaining'||i>=d.turn)&&r.rows[i].speakerName&&r.rows[i].nameOrigin!=='auto').length;
 $('viChangeActions').hidden=!valid||!unprotected.length;
 const changes=valid?changesFor(r,g.indices,d):[],count=changes.length;
 $('viAssign').disabled=!count;$('viAssign').textContent=scopeLabels[d.scope];
 $('viScopeToggle').hidden=g.indices.length<2;
 for(const b of $('viScopeChoices').querySelectorAll('[data-scope]'))b.setAttribute('aria-pressed',String(d.scope===b.dataset.scope));
 const effect=$('viChangeCount');
 effect.textContent='К изменению: '+groupCount(count)+(protectedCount&&!d.overwrite?' · ручные назначения сохранятся':'');
 for(const mark of $('detail').querySelectorAll('[data-vi-change]'))mark.hidden=!changes.includes(Number(mark.dataset.viChange));
 const original=r.rows[d.turn];
 $('viPreviousName').textContent=original.speakerName&&d.name!==original.speakerName?'Сейчас: '+original.speakerName:'';
 $('viGroupOverwrite').checked=d.overwrite;
 $('viGroupProtection').hidden=!protectedCount;
 $('viGroupOverwriteLabel').textContent='Заменить ручные назначения ('+protectedCount+')';
}
function assignmentOrigin(t){return !t.speakerName?'Имя не назначено':t.nameOrigin==='auto'?'Определено автоматически':'Назначено вручную';}
function continuesSpeaker(row,previous){
 return !!row.speakerName&&row.speakerName===previous?.speakerName&&row.identity===previous.identity&&row.nameOrigin===previous.nameOrigin&&groupKey(row)===groupKey(previous);
}
function originMark(t){
 if(!t.speakerName)return '';
 const label=assignmentOrigin(t);
 return '<span class="vi-origin" role="img" aria-label="'+label+'" title="'+label+'">'+icon(t.nameOrigin==='auto'?'speaker-auto':'speaker-manual')+'</span>';
}
function groupPresentation(r,g){
 const named=g.indices.map(i=>r.rows[i]).filter(t=>t.speakerName);
 const identities=new Set(named.map(t=>t.identity||t.speakerName));
 const first=named[0],p=vi.profiles.find(p=>p.id===first?.identity);
 if(identities.size>1)return {name:'Разные имена',detail:'Смешанная группа'};
 if(!first)return {name:g.label,detail:'Нужно имя'};
 const onlyOrigin=named.length===g.indices.length&&named.every(t=>t.nameOrigin===first.nameOrigin);
 return {name:first.speakerName,mark:onlyOrigin?originMark(first):'',detail:named.length<g.indices.length?'Есть реплики без имени':matchingProfiles(first.speakerName).length>1?contact(p):''};
}
function visibleGroups(r,onlyUnknown){return groups(r).filter(g=>!onlyUnknown||g.indices.some(i=>!r.rows[i].speakerName));}
function renderReview(){
 const r=selected();if(!r||vi.review!==r.id)return;
 const gs=groups(r),g=gs.find(g=>g.key===vi.group);if(!g||!g.indices.includes(vi.turn))return;
 const d=groupDraft(),t=r.rows[vi.turn];
 const listScroll=$('detail').querySelector('.vi-groups')?.scrollTop||0;
 $('detail').classList.add('vi-review-host');$('player').hidden=false;$('seek').max=r.duration;
 $('exportButton').disabled=false;$('menuButton').disabled=false;
 $('viewLabel').textContent='Имена участников';
 const unknown=visibleGroups(r,true),visible=visibleGroups(r,vi.onlyUnknown);
 const header='<header class="vi-review-head"><span class="od-truncate" title="'+esc(r.title)+'">'+esc(r.title)+'</span>'+viButton('transcript','К транскрипту','btn')+'</header>';
 const filter='<div class="vi-filter" role="group" aria-label="Фильтр голосов">'+viButton('filter-groups','Все <span>'+gs.length+'</span>','vi-filter-button','id="viFilterAll" data-filter="all" aria-pressed="'+(!vi.onlyUnknown)+'"')+viButton('filter-groups','Неопознанные <span>'+unknown.length+'</span>','vi-filter-button','id="viFilterUnknown" data-filter="unknown" aria-pressed="'+vi.onlyUnknown+'"')+'</div>';
 const list=visible.map(item=>{
  const info=groupPresentation(r,item);
  return viButton('group','<strong>'+esc(info.name)+(info.mark||'')+'</strong>'+(info.detail?'<small>'+esc(info.detail)+'</small>':'')+'<small>'+esc(item.source)+' · '+groupCount(item.indices.length)+'</small>','vi-group','data-group="'+esc(item.key)+'" aria-current="'+(item.key===g.key)+'"');
 }).join('');
 const sampleButton=i=>viButton('play-sample',icon('play')+'<span>'+clock(r.rows[i].t)+'</span>','btn','data-index="'+i+'" aria-pressed="false" aria-label="Воспроизвести демо с '+clock(r.rows[i].t)+'"');
 const changeMark=i=>'<small class="vi-turn-change" data-vi-change="'+i+'" hidden>Имя изменится</small>';
 const otherTurns=g.indices.filter(i=>i!==vi.turn).map(i=>{
  const row=r.rows[i],person=vi.profiles.find(p=>p.id===row.identity);
  const same=row.identity===t.identity&&row.speakerName===t.speakerName&&row.nameOrigin===t.nameOrigin;
  return '<li class="vi-related-turn">'+sampleButton(i)+viButton('select-turn',
   (same?'':'<small>'+esc(person?personLabel(person):row.speakerName||'Без имени')+originMark(row)+'</small>')+'<span>'+esc(row.text)+'</span>'+changeMark(i),
   'vi-other-turn','data-index="'+i+'" title="Выбрать реплику с '+clock(row.t)+'"')+'</li>';
 }).join('');
 const context='<section class="vi-sample" aria-labelledby="viCurrentName"><div class="vi-turn-tools"><h2 tabindex="-1" id="viCurrentName">Реплика</h2>'+sampleButton(vi.turn)+(t.speakerName?originMark(t):hintMarkup(r,vi.turn))+changeMark(vi.turn)+viButton('next-group','Следующий голос →','btn plain vi-next')+'</div><blockquote>'+esc(t.text)+'</blockquote></section>';
 const assignment='<section class="vi-assignment" aria-label="Изменить назначение"><div class="vi-name-block"><label for="viGroupName">Имя участника</label><div class="vi-pick"><input type="text" id="viGroupName" maxlength="120" autocomplete="off" value="'+esc(d.name)+'" placeholder="Найти или добавить человека" aria-describedby="viPreviousName viGroupError">'+viButton('people-options',icon('chevron-down'),'btn','id="viPeopleToggle" aria-label="Показать людей" aria-expanded="false" aria-controls="viPersonOptions"')+'</div><div class="vi-person-options" id="viPersonOptions" aria-label="Люди и календарь" hidden></div><p class="vi-muted vi-previous-name" id="viPreviousName"></p><div id="viGroupIdentity">'+identityMarkup(d)+'</div><p class="error" id="viGroupError" role="status" hidden></p></div>'+
 '<div id="viChangeActions" hidden><div class="vi-editor-actions"><div class="vi-split">'+viButton('assign','Применить ко всем','btn primary','id="viAssign"')+viButton('scope-options',icon('chevron-down'),'btn primary','id="viScopeToggle" aria-label="Область применения" aria-expanded="false" aria-controls="viScopeChoices"')+'</div>'+viButton('cancel-edit','Отменить правку','btn plain')+'</div>'+
 '<div id="viScopeChoices" class="vi-scope-options" role="group" aria-label="Область применения" hidden>'+[['group','Все реплики этого голоса'],['one','Только эта реплика'],['remaining','Эта и следующие']].map(([scope,label])=>viButton('choose-scope',label,'btn','data-scope="'+scope+'" aria-pressed="false"')).join('')+'</div>'+
 '<p id="viChangeCount" class="vi-muted vi-change-count" role="status"></p><label class="vi-protect" id="viGroupProtection" hidden><input type="checkbox" id="viGroupOverwrite"><span id="viGroupOverwriteLabel"></span></label></div></section>';
 const supporting=otherTurns?'<section class="vi-editor-samples" aria-labelledby="viOtherTurns"><h3 id="viOtherTurns">Другие реплики этого спикера</h3><ul class="vi-turns">'+otherTurns+'</ul></section>':'';
 const detail=visible.length?viButton('all-groups','‹ К списку голосов','btn vi-back')+context+assignment+supporting:'<div class="vi-filter-empty" role="status"><h2>Неопознанных голосов нет</h2><p>В разделе «Все» можно проверить или исправить имена.</p></div>';
 $('detail').innerHTML='<section class="vi-review" data-pane="'+(visible.length?vi.pane:'empty')+'" aria-label="Имена участников">'+header+
 '<div class="vi-review-body"><aside class="vi-voice-list">'+filter+'<nav class="vi-groups" aria-label="Выбрать голос">'+list+'</nav></aside><section class="vi-group-detail" aria-label="Выбранная реплика">'+detail+'</section></div></section>';
 $('detail').querySelector('.vi-groups').scrollTop=listScroll;updateGroupPreview();updatePlayer();
}
const originalRenderDetail=renderDetail;
renderDetail=function(){
 autoIdentifyRecord(selected());
 if(vi.review===state.selected){renderReview();return;}
 $('viewLabel').textContent='Транскрипт';
 $('detail').classList.remove('vi-review-host');originalRenderDetail();
 const r=selected();if(!r||r.status!=='ready')return;
 const metadata=$('detail').querySelector('.metadata');if(!metadata)return;
 const old=metadata.lastElementChild;
 const button=document.createElement('button');button.type='button';button.className='speaker-button';button.dataset.vi='open-review';button.id='viOpenReview';button.innerHTML=icon('people')+groups(r).length+' говорящих ›';
 old.replaceWith(button);
 const note=document.createElement('p');note.className='vi-muted';note.textContent='Приглашены: '+fictionalCalendar.map(p=>p.name).join(', ')+'. Голос определяется и у гостей вне приглашения.';metadata.after(note);
 if(r.voiceAuto){
  const unknown=groups(r).filter(g=>g.indices.some(i=>!r.rows[i].speakerName));
  const summary=document.createElement('section');summary.className='vi-result-summary';summary.setAttribute('aria-label','Имена участников');
  const title=unknown.length?'Знакомые голоса определены автоматически':'Все участники уже подписаны';
  const unnamed=r.rows.filter(t=>!t.speakerName).length;
 const subtitle=unknown.length?'Без имени: '+groupCount(unnamed)+'.':'';
  summary.innerHTML='<div><h2>'+title+'</h2><p>'+subtitle+'</p></div>'+(unknown.length?viButton('review-unknown','Разобрать неопознанных','btn primary'):icon('check'));
  if(!vi.enabled||!vi.model)summary.innerHTML='<div><h2>'+(!vi.enabled?'Автоматическое определение выключено':'Модель голосов не подготовлена')+'</h2><p>Имена можно назначить вручную. Настройте определение для следующих записей.</p></div>'+viButton('settings-voice','Настроить голоса','btn');
  note.after(summary);
  $('detail').querySelectorAll('[data-turn]').forEach(el=>{
   const index=Number(el.dataset.turn),t=r.rows[index],speaker=el.querySelector('.speaker-button');
   if(!speaker)return;
   const label='Изменить имя: '+speakerLabel(t)+'. '+assignmentOrigin(t);
   speaker.setAttribute('aria-label',label);
   if(continuesSpeaker(t,r.rows[index-1])){
    el.classList.add('vi-turn-continuation');
    speaker.className='icon-button turn-speaker-action';
    speaker.title=label;speaker.innerHTML=icon('people');
   }else{
    speaker.innerHTML=esc(speakerLabel(t))+(t.speakerName?originMark(t):' · Назначить имя');
   }
  });
 }
};
function openEditor(index=null,unknown=false){
 const r=selected();if(!r||r.status!=='ready')return;
 autoIdentifyRecord(r);
 if(index===null){index=unknown?r.rows.findIndex(t=>!t.speakerName):vi.editorRecord===r.id&&Number.isInteger(vi.turn)?vi.turn:0;}
 if(!Number.isInteger(index)||!r.rows[index])return;
 if(vi.review!==r.id)vi.transcriptScroll=$('detail').scrollTop;
 vi.review=r.id;vi.editorRecord=r.id;vi.turn=index;vi.group=groupKey(r.rows[index]);vi.onlyUnknown=unknown;vi.pane='detail';
 renderReview();$('viCurrentName').focus();
}
function openReview(unknown=false){openEditor(null,unknown);}
function setReviewFilter(onlyUnknown){
 const r=selected();if(!r||vi.review!==r.id)return;
 vi.onlyUnknown=onlyUnknown;
 const visible=visibleGroups(r,onlyUnknown);
 if(visible.length&&!visible.some(g=>g.key===vi.group)){
  const g=visible[0];vi.group=g.key;vi.turn=onlyUnknown?g.indices.find(i=>!r.rows[i].speakerName):g.indices[0];
 }
 renderReview();$('viFilter'+(onlyUnknown?'Unknown':'All')).focus({preventScroll:true});
}
function backToTranscript(index=null){
 vi.review=null;renderDetail();
 if(index!==null){const row=$('detail').querySelector('[data-turn="'+index+'"]');row?.scrollIntoView({block:'center'});row?.querySelector('[data-speaker-turn]')?.focus({preventScroll:true});}
 else{$('detail').scrollTop=vi.transcriptScroll;$('viOpenReview')?.focus({preventScroll:true});}
}
function saveEditor(scope=groupDraft().scope){
 const r=selected(),g=activeGroup(),d=groupDraft();
 const outcome=commitName(r,g.indices,{...d,scope});
 if(!outcome.ok)return;
 vi.drafts.delete(draftKey(r,vi.turn));renderList();renderReview();($('viCurrentName')||$('viFilterUnknown')).focus({preventScroll:true});toast(outcome.message);
}
function discardCurrentDraft(){vi.drafts.delete(draftKey(selected(),vi.turn));}
function cancelEditor(){
 discardCurrentDraft();
 renderReview();
 $('viGroupName')?.focus({preventScroll:true});
}
function advanceGroup(){
 const r=selected(),gs=groups(),at=gs.findIndex(g=>g.key===vi.group);
 const candidates=[...gs.slice(at+1),...gs.slice(0,at)];
 const next=vi.onlyUnknown?candidates.find(g=>g.indices.some(i=>!r.rows[i].speakerName)):candidates[0];
 if(!next){toast(vi.onlyUnknown?'Больше нет неопознанных голосов.':'Больше нет групп.');return;}
 const index=vi.onlyUnknown?next.indices.find(i=>!r.rows[i].speakerName):next.indices[0];
 openEditor(index,vi.onlyUnknown);
}
function confirmDelete(person=null){
 vi.deleteTarget=person;
 const p=vi.profiles.find(p=>p.id===person);
 $('viDeleteTitle').textContent=p?'Удалить человека?':'Удалить все голосовые профили?';
 $('viDeleteCopy').textContent=p?'Будут удалены человек «'+personLabel(p)+'» и его голосовой профиль.':'Будет удалена вся локальная база голосовых профилей ('+vi.profiles.length+').';
 $('viDeletePreserve').textContent='Записи, текст и уже сохранённые имена останутся. Отменить удаление после подтверждения нельзя.';
 const trigger=$(person?'viPersonOptionsButton':'viDirectoryOptions');
 $(person?'viProfileMenu':'viDirectoryMenu')?.hidePopover();
 trigger?.focus({preventScroll:true});
 openDialog('viDeleteDialog');$('viDeleteCancel').focus();
}
function deleteProfiles(){
 const id=vi.deleteTarget;
 vi.profiles=id?vi.profiles.filter(p=>p.id!==id):[];
 refreshProfileViews();closeDialog('viDeleteDialog');
 requestAnimationFrame(()=>$('viPeopleSearch').focus({preventScroll:true}));
 toast(id?'Человек удалён. Имена в записях сохранены.':'Голосовые профили удалены. Имена в записях сохранены.');
}
document.addEventListener('click',event=>{
 if(!event.target.closest('.vi-name-block'))showPersonOptions(false);
 const b=event.target.closest('[data-vi]');if(!b||b.disabled)return;
 const action=b.dataset.vi;
 switch(action){
 case 'open-review':openReview(false);break;
 case 'review-unknown':openReview(true);break;
 case 'filter-groups':setReviewFilter(b.dataset.filter==='unknown');break;
 case 'person':
  vi.person=vi.person===b.dataset.person?null:b.dataset.person;
  renderPeople();$('vi-row-'+b.dataset.person)?.focus({preventScroll:true});break;
 case 'reset-person':confirmReset(b.dataset.person);break;
 case 'confirm-reset':resetLearning();break;
 case 'transcript':backToTranscript(vi.turn);break;
 case 'all-groups':vi.pane='list';renderReview();$('detail').querySelector('[aria-current=true]')?.focus();break;
 case 'group':{const g=groups().find(g=>g.key===b.dataset.group);if(g)openEditor(vi.onlyUnknown?(g.indices.find(i=>!selected().rows[i].speakerName)??g.indices[0]):g.indices[0],vi.onlyUnknown);break;}
 case 'select-turn':openEditor(Number(b.dataset.index),vi.onlyUnknown);break;
 case 'people-options':showPersonOptions($('viPersonOptions').hidden,false);break;
 case 'choose-person':
 case 'calendar-name':
 case 'new-person':{
  const d=groupDraft();
  const person=vi.profiles.find(p=>p.id===b.dataset.person);
  const invite=fictionalCalendar.find(p=>p.email===b.dataset.email);
  d.name=person?.name||invite?.name||d.name.trim();
  d.identity=person?.id||'new';d.email=invite?.email||'';d.note='';d.overwrite=false;
  $('viGroupName').value=d.name;showPersonOptions(false);renderGroupIdentity();updateGroupPreview();$('viGroupError').hidden=true;
  ($('viNewEmail')||$('viGroupName')).focus();break;
 }
 case 'scope-options':
  $('viScopeChoices').hidden=!$('viScopeChoices').hidden;b.setAttribute('aria-expanded',String(!$('viScopeChoices').hidden));break;
 case 'choose-scope':
  groupDraft().scope=b.dataset.scope;$('viScopeToggle').click();updateGroupPreview();$('viScopeToggle').focus();break;
 case 'assign':saveEditor();break;
 case 'cancel-edit':cancelEditor();break;
 case 'next-group':advanceGroup();break;
 case 'settings-voice':openVoiceSettings();break;
 case 'prepare':preparation();break;
 case 'delete-person':confirmDelete(b.dataset.person);break;
 case 'delete-all':confirmDelete();break;
 case 'confirm-delete':deleteProfiles();break;
 case 'play-sample':{
  const index=Number(b.dataset.index),r=selected();
  if(state.playing&&state.clipTurn===index){state.playing=false;state.clipTurn=null;}
  else{state.position=r.rows[index].t;state.clipTurn=index;state.playing=true;}
  updatePlayer();break;
 }
 }
});
document.addEventListener('input',event=>{
 if(event.target.id==='viPeopleSearch'){vi.profileQuery=event.target.value;renderPeople();}
 if(event.target.id==='viGroupName'){
  const d=groupDraft();d.name=event.target.value;d.identity='';d.email='';d.note='';d.overwrite=false;
  renderGroupIdentity();showPersonOptions(true);updateGroupPreview();$('viGroupError').hidden=true;
 }
 if(event.target.id==='viNewEmail'||event.target.id==='viNewNote'){
  groupDraft()[event.target.id==='viNewEmail'?'email':'note']=event.target.value;
  updateGroupPreview();$('viGroupError').hidden=true;
 }
});
document.addEventListener('change',event=>{
 if(event.target.id==='viEnabled'){
  vi.enabled=event.target.checked;
  if(!vi.enabled){vi.profiles.forEach(p=>{if(p.status==='Обновляется'){p.revision++;p.status=p.available?'Готов':'Недостаточно речи';}});}
  renderProfiles();
 }
 if(event.target.id==='viGroupOverwrite'){groupDraft().overwrite=event.target.checked;updateGroupPreview();}
});
function showAssignmentError(){
 const d=groupDraft(),error=$('viGroupError');
 error.textContent=validName(d.name)?identityError(d):'Укажите имя без служебных символов.';
 error.hidden=!error.textContent;
}
document.addEventListener('focusout',event=>{
 if(['viGroupName','viNewEmail','viNewNote'].includes(event.target.id)&&$('viGroupError')&&groupDraft().name.trim())showAssignmentError();
});
document.addEventListener('keydown',event=>{
 if(event.key==='Escape'&&document.querySelector('.context-help:popover-open'))return;
 if(event.target.id==='viGroupName'&&(event.key==='ArrowDown'||(event.key==='Enter'&&!$('viPersonOptions').hidden))){
  event.preventDefault();
  if($('viPersonOptions').hidden)showPersonOptions(true,!groupDraft().identity);
  $('viPersonOptions').querySelector('button')?.focus();
  return;
 }
 if(event.key==='Enter'&&['viGroupName','viNewEmail','viNewNote'].includes(event.target.id)){event.preventDefault();showAssignmentError();$('viAssign').click();}
 if(event.key==='Escape'&&$('viPersonOptions')&&!$('viPersonOptions').hidden){
  event.preventDefault();showPersonOptions(false);$('viGroupName').focus();return;
 }
 if(event.key==='Escape'&&$('viScopeChoices')&&!$('viScopeChoices').hidden){event.preventDefault();$('viScopeToggle').click();$('viScopeToggle').focus();return;}
 if(event.key==='Escape'&&!event.defaultPrevented&&vi.review===state.selected&&!document.querySelector('dialog[open]')){
  event.preventDefault();discardCurrentDraft();backToTranscript(vi.turn);
 }
});
const originalUpdatePlayer=updatePlayer;
updatePlayer=function(){
 originalUpdatePlayer();
 if(vi.review!==state.selected)return;
 const r=selected();
 for(const button of $('detail').querySelectorAll('[data-vi="play-sample"]')){
  const index=Number(button.dataset.index),playing=state.playing&&state.clipTurn===index;
  if(button.getAttribute('aria-pressed')===String(playing))continue;
  button.setAttribute('aria-pressed',String(playing));
  button.setAttribute('aria-label',(playing?'Остановить демо с ':'Воспроизвести демо с ')+clock(r.rows[index].t));
  button.innerHTML=icon(playing?'pause':'play')+'<span>'+clock(r.rows[index].t)+'</span>';
 }
};
const originalSettings=actions.settings;
actions.settings=()=>{originalSettings();renderProfiles();};
const oldSelectRecord=selectRecord;
selectRecord=function(id){vi.review=null;oldSelectRecord(id);};
const oldReset=actions['confirm-reset-models'];
actions['confirm-reset-models']=()=>{oldReset();toast('Кэш моделей сброшен. Голосовые профили, записи и имена сохранены.');};
const oldStopRecording=actions.stop;
actions.stop=()=>{
 oldStopRecording();const r=records.find(r=>r.id===state.session?.id);if(!r)return;
 r.voiceAuto=true;r.rows=demoRows.filter(t=>t.s===0||t.s===3||t.s===6).slice(0,7).map((t,i)=>({...t,t:i*8,speakerName:undefined,identity:null,nameOrigin:undefined,voiceCase:t.expectedProfileId?'found':'unknown'}));r.duration=Math.max(r.duration,60);
 const id=r.id;
 const tick=()=>{if(state.session?.id!==id||state.session.phase!=='processing')return;nextProcessingStage();if(state.session?.phase==='processing')setTimeout(tick,700);};
 setTimeout(tick,700);
};
window.voiceIdentity={state:vi,groups,visibleGroups,setReviewFilter,createEditorDraft,getEditorDraft,selectedTargets,changesFor,commitName,saveEditor,cancelEditor,assignKnownRows,resetProfileLearning,autoIdentifyRecord,backToTranscript,openEditor,openReview,renderReview};
const fixture={rows:[{s:0,source:'mic'},{s:0,source:'mic',speakerName:'Ручное имя'},{s:0,source:'system'}]};
console.assert(selectedTargets(fixture,[0,1],{scope:'group',turn:0,overwrite:false}).join(',')==='0','Manual protection preserves existing names');
console.assert(selectedTargets(fixture,[0,1],{scope:'one',turn:1,overwrite:false}).join(',')==='1','Point correction remains possible');
console.assert(groups(records[0]).length===7,'Synthetic fixture includes seven source groups');
console.assert(new Set(profileSeed().map(p=>p.id)).size===25,'People have separate identities');
// Checks cover the safety boundaries, not the rendering implementation.
const testProfile={id:'test-person',name:'Тестовый человек',available:true,status:'Готов',revision:0,manualSources:2};
const testRows=[{voiceCase:'found',expectedProfileId:'test-person'},{voiceCase:'found',expectedProfileId:'test-person',speakerName:'Ручная правка',nameOrigin:'manual'},{voiceCase:'ambiguous',expectedProfileId:'test-person'}];
assignKnownRows(testRows,[testProfile],true,true);
console.assert(testRows[0].speakerName==='Тестовый человек'&&testRows[0].nameOrigin==='auto'&&testRows[1].speakerName==='Ручная правка'&&!testRows[2].speakerName,'Automatic naming preserves manual corrections and abstains on ambiguity');
resetProfileLearning(testProfile);
const afterReset=[{voiceCase:'found',expectedProfileId:'test-person'}];assignKnownRows(afterReset,[testProfile],true,true);
console.assert(!afterReset[0].speakerName&&testProfile.manualSources===0&&testProfile.revision===1&&testRows[0].speakerName==='Тестовый человек','Reset stops future recognition and keeps names in old transcripts');
const unchangedCount=vi.profiles.reduce((n,p)=>n+(p.manualSources||0),0);autoIdentifyRecord(selected());
console.assert(vi.profiles.reduce((n,p)=>n+(p.manualSources||0),0)===unchangedCount,'Automatic names never add training sources');
const sharedFixture={speakerName:'Анна Лебедева',identity:'person-anna',nameOrigin:'auto'};
const sharedDraft=createEditorDraft(sharedFixture,0,profileSeed());
console.assert(sharedDraft.name===sharedFixture.speakerName&&sharedDraft.identity===sharedFixture.identity&&sharedDraft.scope==='group','Unified editor starts with saved automatic identity and the group action');
console.assert(changesFor({rows:[sharedFixture]},[0],sharedDraft).length===0,'Opening an automatic assignment never converts it into training data');
renderProfiles();renderList();renderDetail();
if(scenario==='voices'||scenario==='settings'||scenario==='off'||scenario==='model'||scenario==='stale'||scenario==='update-error'||scenario==='long-name')openVoiceSettings();
if(scenario==='editor')openReview();
if(scenario==='processing'){startProcessingDemo();$('pipelineDemoPanel').hidden=false;}
})();
