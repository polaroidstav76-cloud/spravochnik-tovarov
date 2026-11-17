const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');
const source=fs.readFileSync(require('node:path').join(__dirname,'../attendance-monitor.js'),'utf8');
async function harness(role='admin'){
 const {document}=parseHTML('<html><body><button id="reportsBtn">Reports</button></body></html>');
 const intervals=[],calls=[];let excluded=false;
 const ctx={document,Date,Map,Number,String,Array,Promise,setInterval:f=>intervals.push(f),staffAccount:{user_id:'one',role},navigator:{clipboard:{writeText:async t=>ctx.copied=t}},confirm:()=>true,prompt:()=> 'Не открывался из-за ремонта',open:id=>document.getElementById(id).classList.add('show'),close:id=>document.getElementById(id).classList.remove('show'),
 db:{rpc:async(name,args)=>{assert.equal(name,'attendance_admin');calls.push(args);let data;
 switch(args.p_action){case 'settings':data={branches:[{id:5,name:'<img src=x>',enabled:true,opening:'10:00:00',closing:'20:00:00',monitor_from:'2026-11-17'}],devices:[]};break;
 case 'pair':data={code:'a'.repeat(32)};break;
 case 'exclude':excluded=args.p_payload.excluded;data={saved:true};break;
 case 'report':data={days:[{branch_id:5,branch:'<img src=x>',day:'2026-11-17',person_id:2,person:'<script>x</script>',opening:'10:00:00',boot_at:'2026-11-17T07:15:00Z',minutes_late:15,counted:!excluded,excluded,note:excluded?'Ремонт':'',schedule_status:'scheduled'},
 {branch_id:6,branch:'Branch 2',day:'2026-11-17',person_id:3,person:'Helper',opening:'10:00:00',boot_at:null,counted:false,schedule_status:'scheduled',continuous:true}],delivery_errors:0};break;
 default:data={saved:true};}
 return {data};}}};vm.createContext(ctx);vm.runInContext(source,ctx);return {document,ctx,calls,intervals};
}
(async()=>{
 const staff=await harness('staff');assert(staff.document.getElementById('attendanceMonitorBtn').hidden);await staff.document.getElementById('attendanceMonitorBtn').onclick();assert.equal(staff.calls.length,0);
 const h=await harness();assert(!h.document.getElementById('attendanceMonitorBtn').hidden);await h.document.getElementById('attendanceMonitorBtn').onclick();assert(h.document.getElementById('attendanceModal').classList.contains('show'));
 assert.equal(h.document.querySelector('img'),null);assert.equal(h.document.querySelector('script'),null);assert(h.document.getElementById('amSummary').textContent.includes('15'));assert(!h.document.getElementById('amSummary').textContent.includes('Helper'));
 await h.document.querySelector('[data-pair]').onclick();await h.document.getElementById('amCopy').onclick();assert.equal(h.ctx.copied,'a'.repeat(32));
 await h.document.querySelector('[data-am-exclude]').onclick();assert(h.calls.some(x=>x.p_action==='exclude'&&x.p_payload.excluded));assert(h.document.getElementById('amSummary').textContent.includes('нет дней'));
 h.ctx.staffAccount={user_id:'two',role:'staff'};h.intervals[0]();assert(h.document.getElementById('attendanceMonitorBtn').hidden);assert.equal(h.document.getElementById('amPair').textContent,'');assert(!h.document.getElementById('attendanceModal').classList.contains('show'));
 console.log('PASS attendance UI: admin only, XSS escaping, primary-employee totals, unknown days excluded, pair copying, manual exclusion and account-switch cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
