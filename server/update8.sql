-- 상담 신청에 대면/비대면 선택 저장
create or replace function public.fw_inquiry(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_id text:=gen_random_uuid()::text; v_ph text:=left(coalesce(p->>'parent',''),20);
begin
  if length(regexp_replace(v_ph,'[^0-9]','','g'))<9 or coalesce(trim(p->>'name'),'')='' then raise exception 'bad'; end if;
  if (select count(*) from fw_rec where col='I' and updated_at>now()-interval '10 minutes')>=15 then raise exception 'busy'; end if;
  insert into fw_rec(col,id,data,sid,updated_at) values('I',v_id,jsonb_build_object(
    'id',v_id,'status','new','at',to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI'),
    'name',left(trim(p->>'name'),20),'parent',v_ph,'school',left(coalesce(p->>'school',''),30),
    'grade',left(coalesce(p->>'grade',''),15),'msg',left(coalesce(p->>'msg',''),600),'type',left(coalesce(p->>'type',''),10)),null,clock_timestamp());
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.fw_inquiry(jsonb) to anon, authenticated;

select 'OK' as result;
