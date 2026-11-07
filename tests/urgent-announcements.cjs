const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const source=html.slice(html.indexOf('let annShowing=false;'),html.indexOf('function showOneAnnouncement'));
let announcements=[{id:1,is_active:true},{id:2,is_active:true,is_urgent:true},{id:3,is_active:false,is_urgent:true}];
let reads=[{announcement_id:2,person_id:1}],shown=[],queries=0,fail=false;
const ctx=vm.createContext({console,esc:String,salesSession:{shiftId:1,participants:[{personId:1},{personId:2},{personId:3,isActive:false}]},
  showOneAnnouncement:async(x)=>{shown.push(x)},
  db:{from:table=>{queries++;const filters=[];const q={select:()=>q,eq:(k,v)=>{filters.push([k,v]);return q},in:()=>q,order:()=>q,then:fn=>Promise.resolve(fail?{error:{message:'offline'}}:{data:table==='announcements'?announcements.filter(x=>filters.every(([k,v])=>x[k]===v)):reads}).then(fn)};return q}},
});
vm.runInContext(source,ctx);
(async()=>{
  await ctx.showAnnouncements(true);
  assert.equal(shown.length,1);assert.equal(shown[0].id,2);
  assert.deepEqual(Array.from(shown[0].unread,p=>p.personId),[2]);
  shown=[];await ctx.showAnnouncements();assert.deepEqual(shown.map(x=>x.id),[2,1]);
  shown=[];await Promise.all([ctx.showAnnouncements(true),ctx.showAnnouncements(true)]);assert.equal(shown.length,1);
  ctx.salesSession=null;const n=queries;await ctx.showAnnouncements(true);assert.equal(queries,n);
  ctx.salesSession={shiftId:1,participants:[{personId:1}]};shown=[];await ctx.showAnnouncements(true);assert.equal(shown.length,0);
  reads=[];await ctx.showAnnouncements(true);assert.equal(shown.length,1);
  console.log('PASS: urgent-only live delivery, shift-open backlog, urgency order, per-person reads, inactive participants, concurrent checks, no shift');
})().catch(e=>{console.error(e);process.exitCode=1});
