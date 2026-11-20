/* Local recovery of selected original Files and not-yet-published edits. */
(()=>{
 let opened;
 function database(){if(!opened)opened=new Promise((resolve,reject)=>{const r=indexedDB.open('polaroid-photo-drafts',2);r.onupgradeneeded=()=>{const s=r.result.objectStoreNames.contains('items')?r.transaction.objectStore('items'):r.result.createObjectStore('items',{keyPath:'key'});if(!s.indexNames.contains('by_order'))s.createIndex('by_order',['token','kind']);if(!s.indexNames.contains('by_queue'))s.createIndex('by_queue',['token','kind','state']);};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});return opened;}
 async function transaction(mode,fn){const db=await database();return new Promise((resolve,reject)=>{const tx=db.transaction('items',mode),r=fn(tx.objectStore('items'));let result;r.onsuccess=()=>result=r.result;r.onerror=()=>reject(r.error);tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});}
 const key=(token,id,kind)=>token+':'+kind+':'+id;
 const put=(token,id,kind,value)=>transaction('readwrite',s=>s.put({key:key(token,id,kind),token,id,kind,state:value?.pending?'pending':'ready',value}));
 const get=async(token,id,kind)=>(await transaction('readonly',s=>s.get(key(token,id,kind))))?.value;
 const remove=(token,id,kind)=>transaction('readwrite',s=>s.delete(key(token,id,kind)));
 const list=async(token,kind)=>await transaction('readonly',s=>kind==='original'?s.index('by_queue').getAll(IDBKeyRange.only([token,kind,'pending'])):s.index('by_order').getAll(IDBKeyRange.only([token,kind])));
 PhotoLinks.local={put,get,remove,list};
})();
