-- 쌤톡(선생님 메신저): 1:1 대화는 보낸 사람·받는 사람만, 전체방은 모든 선생님. 학생은 못 봄
create or replace function public.fw_pull(p_token uuid, p_since timestamptz) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.fw_sess; v_now timestamptz:=clock_timestamp(); v_rows jsonb;
begin
  s:=fw_who(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('col',r.col,'id',r.id,'data',
    case
      when r.data is null then null
      when r.col='T' and not (s.role='owner' or r.id=s.uid) then r.data-'pw'
      when r.col='E' and s.role='student' then (r.data-'res')||jsonb_build_object('res',
           case when r.data->'res' ? s.uid then jsonb_build_object(s.uid,r.data->'res'->s.uid) else '{}'::jsonb end)
      else r.data end)),'[]'::jsonb)
  into v_rows
  from fw_rec r
  where (p_since is null and r.data is not null or r.updated_at>p_since)
    and (s.role<>'student' or (r.col not in ('N','L','PC','M','I') and (r.col in ('T','C','E','meta') or r.sid=s.uid)))
    and (r.col<>'M' or r.data is null or r.data->>'room'='all' or r.data->>'by'=s.uid or coalesce(r.data->'to','[]'::jsonb) ? s.uid);
  return jsonb_build_object('now',v_now,'rows',v_rows);
end $$;
select 'OK' as result;
