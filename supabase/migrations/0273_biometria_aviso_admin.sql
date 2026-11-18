-- NIOGEN | supabase/migrations/0273_biometria_aviso_admin.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 17/11 ~22h (caso Geraldo, logado como admin): "Geraldo … mostrando ✓ Biometria validada … e com botão Biometria validada habilitado".
-- O GED360 tinha lido LINK ENVIADO 12 min antes: para o time o botão já some (0272); para o admin ele continua (decisão da 0272),
-- mas a tela não dizia por quê. Agora porta_botoes devolve, junto do ok do admin, a frase "Só o admin vê este botão agora: … (GED360: …)"
-- e a ficha marca o botão. Só a função de leitura muda; a porta (_porta_conferir) é a mesma da 0272.
begin;

-- o texto do "se você clicar" é condicional (caso Geraldo: "induz que a biometria está aprovada, mas ela não está")
update public.config_efeito set efeito = 'Grava à mão que a biometria foi aprovada; depois disso o próximo passo vira gravar a OS.' where evento = 'momento:biometria:validada';
update public.config_efeito set efeito = 'Grava à mão que a biometria ficou com risco; a venda espera a conferência no portal.' where evento = 'momento:biometria:risco';
update public.config_efeito set efeito = 'Grava que a Nio liberou a venda da biometria (sistema dela fora do ar): a venda segue como aprovada e fica registrado quem marcou.' where evento = 'momento:biometria:dispensada';
update public.config_efeito set efeito = 'Grava à mão o que o GED360 ou o portal mostram da biometria.' where evento = 'momento:biometria:*';

create or replace function public.porta_botoes(p_conversa uuid default null, p_venda uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  s text; achou boolean := false; conv uuid := p_conversa; vend uuid := p_venda; sit jsonb; admin boolean; ged text; ged_lido boolean := false;
  ev text; r record; ok boolean; destino text; efeito text; nomes text[]; frase text;
  opt_ok boolean := null; out jsonb := '{}'::jsonb;
begin
  if p_conversa is null and p_venda is null then raise exception 'Informe a conversa ou a venda.'; end if;
  select ls.situacao, ls.conversa_id, ls.venda_id, true into s, conv, vend, achou from public.v_lead_situacao ls
   where (p_conversa is not null and ls.conversa_id = p_conversa) or (p_venda is not null and ls.venda_id = p_venda)
   limit 1;
  if not achou then return null; end if;   -- não existe ou o RLS não deixa ver
  conv := coalesce(conv, p_conversa);
  s := coalesce(s, '(sem situação)');
  admin := coalesce(public.meu_perfil(), '') = 'admin';
  select to_jsonb(x) into sit from (select codigo, numero, nome, vez, chatwoot, mari, lembretes from public.config_situacao where codigo = s) x;

  for ev in
    select distinct t.evento from public.config_transicao t
     where t.evento <> '*' and split_part(t.evento, ':', 1) not in ('nio', 'funil', 'prazo', 'mari_passou', 'conversa')
       and t.evento <> 'cliente_escreveu'
     order by 1
  loop
    select * into r from public.porta_prever(s, ev);
    ok := r.aceito is not false;
    frase := r.frase;
    if r.aceito and r.exige = 'admin' and not admin then
      ok := false;
    elsif r.aceito and r.exige = 'ged_sem_leitura' then   -- 0272: biometria à mão só sem leitura recente do GED360 (ou o admin)
      if not ged_lido then ged := public._ged_fresco(vend); ged_lido := true; end if;
      ok := admin or ged is null;
      -- 0273: o admin continua vendo o botão, mas a tela avisa que é só dele e o que o GED360 diz
      if ged is not null then frase := case when ok then 'Só o admin vê este botão agora: ' else '' end || r.frase || ' (GED360: ' || ged || ')'; end if;
    elsif r.aceito and r.exige = 'cliente_escreveu_depois' then
      if opt_ok is null then   -- mesma conta da porta (0265): o cliente escreveu depois de pedir para parar?
        opt_ok := not exists (
          select 1 from (select max(t.created_at) as em from public.mari_turnos t
                          where t.conversa_id = conv and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%') o
           where o.em is not null
             and not exists (select 1 from public.mari_turnos t where t.conversa_id = conv and t.papel = 'lead' and t.created_at > o.em));
      end if;
      ok := opt_ok;
    end if;
    if r.aceito is not true then frase := coalesce(frase, 'Esta ação não vale nesta situação.');
    elsif ok and not (r.exige = 'ged_sem_leitura' and ged is not null) then frase := null; end if;
    -- para onde vai, em nomes
    select array_agg(case p when '=' then 'fica em ' || coalesce(sit ->> 'nome', s)
                             when 'andamento' then 'volta à etapa onde parou'
                             when '*' then 'qualquer situação'
                             else coalesce((select cs.nome from public.config_situacao cs where cs.codigo = p), p) end order by n)
      into nomes from unnest(r.para) with ordinality u(p, n);
    -- o que acontece: o efeito do evento + o que a situação de destino manda (quando o destino é um só)
    efeito := public._efeito_de(ev);
    if r.aceito and array_length(r.para, 1) = 1 and r.para[1] not in ('=', 'andamento', '*') then
      select concat_ws(' · ', 'Depois: ' || cs.nome, 'vez: ' || cs.vez, 'Mari: ' || cs.mari)
        into destino from public.config_situacao cs where cs.codigo = r.para[1];
      efeito := concat_ws(' ', efeito, regexp_replace(destino, '\s*\([^)]*\)', '', 'g') || '.');
    end if;
    out := out || jsonb_build_object(ev, jsonb_build_object(
      'ok', ok, 'aceito', r.aceito, 'exige', r.exige, 'frase', frase, 'para', to_jsonb(nomes), 'efeito', efeito));
  end loop;

  return jsonb_build_object('situacao', coalesce(sit, jsonb_build_object('codigo', s)), 'admin', admin, 'eventos', out);
end $$;
revoke execute on function public.porta_botoes(uuid, uuid) from public, anon;
grant execute on function public.porta_botoes(uuid, uuid) to authenticated, service_role;
revoke execute on function public.porta_botoes(uuid, uuid) from public, anon;
grant execute on function public.porta_botoes(uuid, uuid) to authenticated, service_role;

commit;
