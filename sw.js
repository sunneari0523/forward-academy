// 예전(ChatGPT) 사이트가 기기에 남긴 서비스워커를 지우는 파일 — 지우지 마세요
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>{e.waitUntil((async()=>{
  try{const ks=await caches.keys();await Promise.all(ks.map(k=>caches.delete(k)))}catch(err){}
  try{await self.registration.unregister()}catch(err){}
  try{const cs=await self.clients.matchAll({type:'window'});cs.forEach(c=>c.navigate(c.url))}catch(err){}
})())});
