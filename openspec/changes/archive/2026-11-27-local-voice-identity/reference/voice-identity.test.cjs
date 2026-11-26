const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {webcrypto}=require('node:crypto');
const source=fs.readFileSync('voice-identity.js','utf8');
const index=fs.readFileSync('index.html','utf8');
const section=(start,end)=>{const a=source.indexOf(start),b=source.indexOf(end,a+start.length);assert(a>=0&&b>a);return source.slice(a,b);};
const logic=section('function groupPresentation(', 'function renderReview(')+section('function groups(', 'function calendarPeople(')+section('function identityError(', 'function hintMarkup(')+section('function continuesSpeaker(', 'function originMark(')+section('function profileAfterManual(', 'const refusal=')+section('function openEditor(', 'function backToTranscript(')+section('function saveEditor(', 'function advanceGroup(');
const bridge=index.slice(index.indexOf('function openSpeakerEditor('),index.indexOf('\nObject.assign(actions',index.indexOf('function openSpeakerEditor(')));
const baseRows=[
 {s:0,source:'mic',text:'Первая',speakerName:'Анна',identity:'anna',nameOrigin:'auto',voiceCase:'found'},
 {s:0,source:'mic',text:'Вторая',speakerName:'Илья',identity:'ilya',nameOrigin:'manual',voiceCase:'found'},
 {s:0,source:'system',text:'Другая дорожка',speakerName:'Анна',identity:'anna',nameOrigin:'auto',voiceCase:'found'},
 {s:1,source:'mic',text:'Новый голос',voiceCase:'unknown'}
];
function setup(){
 const r={id:'meeting',status:'ready',rows:structuredClone(baseRows)};
 const profiles=[['anna','Анна'],['ilya','Илья'],['maria','Мария']].map(([id,name])=>({id,name,available:true,revision:0,status:'Готов',manualSources:2}));
 const vi={profiles,drafts:new Map(),review:null,turn:null,editorRecord:null,enabled:true,model:true,learnedVoices:new Map(),lastNotice:''};
 const callbacks=[];
 const ctx={vi,state:{selected:r.id},selected:()=>r,sourceLabel:t=>t.source,groupKey:t=>t.s+':'+t.source,rowLabel:t=>'Speaker '+(t.s+1),normalized:s=>s.normalize('NFC').trim().toLocaleLowerCase('ru'),autoIdentifyRecord(){},renderReview(){},renderList(){},renderProfiles(){},$:()=>({focus(){},hidden:true}),toast(){},setTimeout:cb=>callbacks.push(cb),crypto:webcrypto,preserveOriginal(record){record.originalRows??=structuredClone(record.rows);},backToTranscript(i){vi.review=null;ctx.returnedTo=i;},window:{}};
 vm.createContext(ctx);vm.runInContext(logic,ctx);ctx.window.voiceIdentity={openEditor:ctx.openEditor};vm.runInContext(bridge,ctx);
 return {ctx,r,vi,callbacks};
}
{
 const {ctx,r,vi,callbacks}=setup(),before=JSON.stringify(r.rows),sources=JSON.stringify(vi.profiles);
 ctx.openReview();const general=ctx.groupDraft();
 assert.equal(general.name,'Анна');assert.equal(general.identity,'anna');assert.equal(general.scope,'group');assert.equal(general.turn,0);
 assert.equal(ctx.changesFor(r,[0,1],general).length,0);
 general.scope='remaining';general.name='Мария';general.identity='maria';
 ctx.openSpeakerEditor(0);assert.equal(ctx.groupDraft(),general);assert.equal(ctx.groupDraft().scope,'remaining');
 assert.equal(JSON.stringify(r.rows),before);assert.equal(JSON.stringify(vi.profiles),sources);assert.equal(callbacks.length,0);
 const other=ctx.getEditorDraft(r,1);other.name='Другой черновик';
 ctx.cancelEditor();
 assert.equal(vi.review,r.id);assert.equal(vi.turn,0);assert.equal(ctx.returnedTo,undefined);
 assert.equal(JSON.stringify(r.rows),before);assert.equal(JSON.stringify(vi.profiles),sources);assert.equal(callbacks.length,0);
 assert.equal(vi.drafts.size,1);assert.equal(ctx.getEditorDraft(r,1),other);
 assert.equal(ctx.groupDraft().name,'Анна');assert.equal(ctx.groupDraft().scope,'one');
}
{
 const {ctx,r,vi,callbacks}=setup();ctx.openReview();
 const draft=ctx.groupDraft();draft.name='Мария';draft.identity='maria';
 const before=JSON.stringify(r.rows),profiles=JSON.stringify(vi.profiles);
 ctx.setReviewFilter(true);assert.equal(vi.onlyUnknown,true);assert.equal(vi.turn,3);assert.equal(ctx.visibleGroups(r,true).length,1);
 ctx.setReviewFilter(false);assert.equal(ctx.visibleGroups(r,false).length,3);
 ctx.openSpeakerEditor(0);assert.equal(ctx.groupDraft(),draft);assert.equal(draft.name,'Мария');
 assert.equal(JSON.stringify(r.rows),before);assert.equal(JSON.stringify(vi.profiles),profiles);assert.equal(callbacks.length,0);
 r.rows[3].speakerName='Денис';const after=JSON.stringify(r.rows);
 ctx.setReviewFilter(true);assert.equal(ctx.visibleGroups(r,true).length,0);ctx.setReviewFilter(false);assert.equal(ctx.visibleGroups(r,false).length,3);assert.equal(JSON.stringify(r.rows),after);
}
{
 const {ctx,r,vi}=setup();
 r.rows.push({s:2,source:'mic',text:'Другой голос',voiceCase:'unknown'});
 ctx.openReview(true);
 const draft=ctx.groupDraft();draft.name='Мария';draft.identity='maria';
 ctx.saveEditor();
 assert.equal(vi.turn,4);
}
{
 const {ctx,r,vi,callbacks}=setup();
 ctx.openReview();assert.equal(ctx.groupDraft().scope,'group');
 ctx.openSpeakerEditor(0);
 assert.equal(ctx.groupDraft().scope,'one');
 vi.profiles=vi.profiles.filter(p=>p.id!=='anna');
 r.rows.push({s:0,source:'mic',text:'Без имени',voiceCase:'unknown'});
 ctx.openSpeakerEditor(0);
 ctx.saveEditor('group');
 assert.equal(r.rows[4].identity,'anna');
 assert.equal(r.rows[4].nameOrigin,'derived');
 assert.equal(vi.profiles.some(p=>p.id==='anna'),false);
 assert.equal(callbacks.length,0);
}
const outcomes=[];
for(const entry of ['openReview','openSpeakerEditor']){
 const {ctx,r,vi,callbacks}=setup();ctx[entry](0);
 const d=ctx.groupDraft();d.name='Мария';d.identity='maria';d.scope='group';
 assert.equal(Array.from(ctx.changesFor(r,[0,1],d)).join(','),'0');
 ctx.saveEditor();
 assert.equal(vi.turn,0);assert.equal(vi.review,'meeting');
 assert.equal(r.rows[0].speakerName,'Мария');assert.equal(r.rows[0].nameOrigin,'manual');
 assert.equal(r.rows[1].speakerName,'Илья');assert.equal(r.rows[2].speakerName,'Анна');
 assert.equal(r.originalRows[0].speakerName,'Анна');assert.equal(callbacks.length,1);
 outcomes.push(JSON.stringify(r.rows));
}
assert.equal(outcomes[0],outcomes[1]);
{
 const {ctx,r}=setup();
 const d={turn:1,scope:'remaining',overwrite:false,name:'Мария',identity:'maria'};
 assert.equal(ctx.changesFor(r,[0,1],d).length,0);
 d.overwrite=true;assert.equal(Array.from(ctx.changesFor(r,[0,1],d)).join(','),'1');
 d.turn=99;assert.equal(ctx.changesFor(r,[0,1],d).length,0);
 const p=ctx.vi.profiles.find(p=>p.id==='maria');
 ctx.openSpeakerEditor(3);const unknown=ctx.groupDraft();unknown.name='Мария';unknown.identity='maria';ctx.saveEditor();
 assert.equal(r.rows[3].speakerName,'Мария');assert.equal(p.status,'Обновляется');
}
{
 const {ctx,r,vi,callbacks}=setup();
 r.rows.push({s:0,source:'mic',text:'Последняя',voiceCase:'unknown'});
 ctx.openSpeakerEditor(4);assert.equal(ctx.groupDraft().name,'');assert.equal(ctx.groupDraft().scope,'one');
 ctx.openSpeakerEditor(0);assert.equal(ctx.groupDraft().identity,'anna');
 ctx.saveEditor('group');
 assert.equal(r.rows[0].nameOrigin,'auto');
 assert.equal(r.rows[1].identity,'ilya');
 assert.equal(r.rows[4].identity,'anna');assert.equal(r.rows[4].nameOrigin,'derived');
 assert.equal(callbacks.length,0);
 ctx.openSpeakerEditor(4);assert.equal(ctx.groupDraft().name,'Анна');
 ctx.openSpeakerEditor(3);
 const typed=ctx.groupDraft();typed.name='Ден';typed.identity='';
 ctx.openSpeakerEditor(0);ctx.openSpeakerEditor(3);
 assert.equal(ctx.groupDraft().name,'Ден');
 assert.equal(vi.turn,3);
}
{
 const {ctx,r,vi,callbacks}=setup();
 vi.enabled=false;vi.profiles[0].email='anna@north.example';
 const d={name:'Анна',identity:'new',turn:0,scope:'one',overwrite:false};
 assert.equal(ctx.commitName(r,[0,1],d).ok,false);
 assert.equal(ctx.commitName(r,[0,1],{...d,email:'ANNA@north.example'}).ok,false);
 assert.equal(ctx.commitName(r,[0,1],{...d,note:'Подрядчик'}).ok,true);
 const person=vi.profiles.find(p=>p.id===r.rows[0].identity);
 assert.equal(person.note,'Подрядчик');
 assert.equal(r.rows[0].nameOrigin,'manual');
 assert.equal(callbacks.length,0);
}
{
 const {ctx,r}=setup();
 r.rows.push({...r.rows[0],text:'Продолжение'});
 ctx.openSpeakerEditor(4);
 const draft=ctx.groupDraft();
 draft.scope='one';draft.name='Мария';draft.identity='maria';
 const previewed=Array.from(ctx.changesFor(r,[0,1,4],draft));
 assert.deepEqual(previewed,[4]);
 ctx.saveEditor();
 assert.equal(r.rows[0].identity,'anna');assert.equal(r.rows[4].identity,'maria');
 assert.equal(ctx.continuesSpeaker(r.rows[0],undefined),false);
 assert.equal(ctx.continuesSpeaker(r.rows[0],{...r.rows[0]}),true);
 assert.equal(ctx.continuesSpeaker(r.rows[0],{...r.rows[0],identity:'different-anna'}),false);
 assert.equal(ctx.continuesSpeaker(r.rows[0],r.rows[2]),false);
 assert.equal(ctx.continuesSpeaker(r.rows[0],{...r.rows[0],nameOrigin:'manual'}),false);
}
const stopRecordingSource=index.slice(index.indexOf('function stopRecording(){'),index.indexOf('function beginProcessing('));
for(const hasDraft of [true,false]){
 const {ctx,r,vi}=setup();
 ctx.records=[r];
 ctx.state.session={phase:'recording',started:Date.now()-5000,title:'Новая запись'};
 ctx.state.position=18;
 ctx.row=(t,s,text)=>({t,s,text});
 ctx.beginProcessing=(id,title)=>{ctx.state.session={id,title,phase:'processing'};};
 ctx.renderDetail=()=>{};
 ctx.selectRecord=id=>{ctx.state.selected=id;ctx.state.position=0;};
 vm.runInContext(section('function canLeaveCurrentResult(', "for(const action of"),ctx);
 vm.runInContext(stopRecordingSource,ctx);
 ctx.openSpeakerEditor(0);
 const draft=ctx.groupDraft();
 if(hasDraft)draft.name='Несохранённое имя';
 ctx.openSpeakerEditor(1);
 ctx.stopRecording();
 assert.equal(ctx.state.session.phase,'processing');
 assert.equal(ctx.records[0].id,ctx.state.session.id);
 assert.equal(ctx.state.selected,hasDraft?r.id:ctx.state.session.id);
 assert.equal(ctx.state.position,hasDraft?18:0);
 if(hasDraft){
  assert.equal(vi.review,r.id);
  assert.equal(ctx.getEditorDraft(r,0).name,'Несохранённое имя');
  ctx.openReview(true);
  assert.equal(vi.turn,0);
  assert.equal(vi.onlyUnknown,false);
 }
}
for(const [name,expected] of [['Мария','maria'],['Новый человек',null]]){
 const {ctx,r,vi,callbacks}=setup();ctx.openSpeakerEditor(3);
 const draft=ctx.groupDraft();draft.name=name;
 assert.equal(vi.profiles.length,3);
 ctx.saveEditor();
 assert.equal(r.rows[3].speakerName,name);
 if(expected)assert.equal(r.rows[3].identity,expected);
 else assert.equal(vi.profiles.find(person=>person.id===r.rows[3].identity).name,name);
 assert.equal(callbacks.length,1);
}
{
 const {ctx,r,vi,callbacks}=setup();ctx.openSpeakerEditor(3);
 vi.profiles.push({id:'maria-2',name:'Мария'});
 ctx.groupDraft().name='Мария';
 assert.match(ctx.identityError(ctx.groupDraft()),/несколько людей/);
 assert.equal(ctx.commitName(r,[3],ctx.groupDraft()).ok,false);
 assert.equal(callbacks.length,0);
}
assert(!index.includes('viImportDialog'));
{
 const {ctx,r}=setup(),group=ctx.groups(r)[0];
 r.rows[1].speakerName=' анна ';r.rows[1].identity='';
 assert.equal(ctx.groupPresentation(r,group).name,'Анна');
 r.rows[1].identity='ilya';
 assert.equal(ctx.groupPresentation(r,group).name,'Разные имена');
}
assert.deepEqual([...index.matchAll(/data-settings-tab="([a-z]+)"/g)].map(match=>match[1]),
 ['general','recording','transcription','calendar','diagnostics','voices']);
{
 const {ctx,r,vi,callbacks}=setup();
 r.rows[1].identity='';r.rows[1].voiceSignature='confirmed-turn';
 ctx.openSpeakerEditor(1);
 const draft=ctx.groupDraft();draft.scope='group';
 assert.equal(ctx.canConfirmSavedName(r,draft),true);
 ctx.saveEditor('group',true);
 assert.equal(r.rows[1].identity,'ilya');
 assert.equal(r.rows[0].identity,'anna');
 assert.equal(r.rows[0].nameOrigin,'auto');
 assert.equal(ctx.canConfirmSavedName(r,ctx.groupDraft()),false);
 assert.equal(callbacks.length,1);
 callbacks.shift()();
 assert.equal(vi.learnedVoices.get('confirmed-turn'),'ilya');
}
{
 const {ctx,r,callbacks}=setup();ctx.openSpeakerEditor(0);
 const draft=ctx.groupDraft();draft.name=' анна ';draft.identity='';
 ctx.saveEditor();
 assert.equal(r.rows[0].identity,'anna');
 assert.equal(r.rows[0].nameOrigin,'derived');
 assert.equal(callbacks.length,0);
}
console.log('PASS: shared editor, Stop preserves outstanding drafts, and saved manual names start learning');
