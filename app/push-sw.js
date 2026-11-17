// 포워드 알림 받기용 (지우지 마세요)
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(err){d={body:e.data&&e.data.text()}}
  e.waitUntil(self.registration.showNotification(d.title||'포워드 영어학원',{body:d.body||'',icon:'/icon-192.png',badge:'/icon-192.png',tag:d.tag||undefined,data:{url:d.url||'/app/index.html'}}));
});
self.addEventListener('notificationclick',e=>{
  e.notification.close();const url=(e.notification.data&&e.notification.data.url)||'/app/index.html';
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{
    for(const c of cs){if(c.url.includes('/app/')&&'focus' in c){c.postMessage({fwPush:1});return c.focus()}}
    return self.clients.openWindow(url);
  }));
});
