-- 숙제 마감 임박 알림: 매일 오후 5시(한국 시간)에 오늘·내일 마감인데 안 낸 숙제가 있는 학생에게 알림
-- (서버 함수 notify를 먼저 새 버전으로 올린 뒤 실행하세요)
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule('fw-hw-remind') where exists (select 1 from cron.job where jobname='fw-hw-remind');
select cron.schedule('fw-hw-remind', '0 8 * * *',  -- 08:00 UTC = 17:00 KST
$$ select net.http_post(
     url := 'https://ltvejlubynybtladghkm.supabase.co/functions/v1/notify',
     headers := '{"Content-Type":"application/json","apikey":"sb_publishable_3trcVQfRXg5HONzqdS2jkg_KyWlV73k"}'::jsonb,
     body := '{"op":"remind"}'::jsonb) $$);

select 'OK' as result;
