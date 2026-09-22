-- Called only after Edge Function validation. One transaction prevents partial AI edits.
create or replace function public.apply_revision_ai_changes(p_plan_id uuid, p_owner_id uuid, p_changes jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare change jsonb; session_row academic_revision_sessions%rowtype;
begin
  for change in select * from jsonb_array_elements(p_changes) loop
    if change->>'action' in ('move','resize') then
      update academic_revision_sessions set scheduled_date=(change->>'scheduled_date')::date, start_time=(change->>'start_time')::time, end_time=(change->>'end_time')::time, generated_reason=coalesce(change->>'reason',generated_reason) where id=(change->>'session_id')::uuid and owner_id=p_owner_id and plan_id=p_plan_id and locked=false and status <> 'done';
      if not found then raise exception 'Protected or missing session'; end if;
    elsif change->>'action' = 'remove' then
      delete from academic_revision_sessions where id=(change->>'session_id')::uuid and owner_id=p_owner_id and plan_id=p_plan_id and locked=false and status <> 'done';
      if not found then raise exception 'Protected or missing session'; end if;
    elsif change->>'action' = 'create' then
      insert into academic_revision_sessions(owner_id,plan_id,exam_id,revision_topic_id,subject_id,topic_id,title,activity_label,scheduled_date,start_time,end_time,status,locked,source,generated_reason,notes)
      values(p_owner_id,p_plan_id,(change->>'exam_id')::uuid,(change->>'revision_topic_id')::uuid,(change->>'subject_id')::uuid,nullif(change->>'topic_id','')::uuid,coalesce(change->>'title','Revision'),change->>'activity_label',(change->>'scheduled_date')::date,(change->>'start_time')::time,(change->>'end_time')::time,'not_started',false,'ai',coalesce(change->>'reason','AI adjustment'),'');
    else raise exception 'Unsupported action'; end if;
  end loop;
end $$;

revoke all on function public.apply_revision_ai_changes(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_revision_ai_changes(uuid, uuid, jsonb) to service_role;
