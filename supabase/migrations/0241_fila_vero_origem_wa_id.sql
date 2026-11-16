-- NIOGEN | supabase/migrations/0241_fila_vero_origem_wa_id.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Fila Vero: a origem pela conversa da Mari também acha a linha quando o telefone da conversa vem sem o 9 (wa_id antigo),
-- como o opt-out da 0240. Só muda o caminho de reserva (sem código na mensagem); o código (FV-xx-<codigo>) continua primeiro.
create or replace function public._fila_vero_origem()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cod text; v public.fila_vero%rowtype; v_tel text;
begin
  begin   -- nunca derruba a gravação do turno da Mari
    v_cod := lower(substring(new.texto from '\(FV-[A-Za-z0-9]+-([a-z0-9]{6,12})\)'));
    if v_cod is not null then
      select * into v from public.fila_vero where codigo = v_cod;
    end if;
    if v.id is null and new.texto ~ '\(FV-' then
      select telefone into v_tel from public.mari_conversas where id = new.conversa_id;
      select * into v from public.fila_vero where id = public._fila_vero_por_wa(null, v_tel);
    end if;
    if v.id is null then return null; end if;
    update public.mari_conversas set origem = 'fila_vero'
     where id = new.conversa_id and coalesce(origem, 'direto') = 'direto';
    update public.fila_vero set conversa_id = coalesce(conversa_id, new.conversa_id),
                                respondeu_em = coalesce(respondeu_em, now()),
                                clicou_em = coalesce(clicou_em, now())
     where id = v.id;
    if v.status in ('apto', 'enviado', 'erro', 'encerrado') then
      perform set_config('niogen.fila_vero_porta', 'on', true);
      perform set_config('niogen.fila_vero_motivo', 'falou com a Mari (código ' || coalesce(v_cod, 'FV') || ')', true);
      perform set_config('niogen.fila_vero_autor', 'mari_turnos', true);
      update public.fila_vero set status = 'respondeu' where id = v.id;
      perform set_config('niogen.fila_vero_porta', 'off', true);
    end if;
  exception when others then
    raise warning 'fila_vero_origem: %', sqlerrm;
  end;
  return null;
end $$;
