-- NIOGEN | supabase/migrations/0298_motivo_acao_admin.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "depois siga para a 2ª leva do passo 6" — motivo nas ações só de admin (decisões D11, D15, E7 de 17/11: "só admin,
-- com motivo"; seção 13 do diagnóstico: "admin com motivo ficou admin (autor gravado) — o campo de motivo pede mudar a ficha").
-- Hoje 13 eventos da porta são só do admin (config_transicao.exige = 'admin'): reabrir Saída definitiva, reativar e responder cliente
-- Nio, Nio dispensou a biometria, biometria/OS/pedido depois da OS ou da agenda, trocar titular depois da biometria, Mover. Só o Mover
-- pedia o motivo. Agora:
--  (1) porta(): ação de admin sem motivo é recusada com "MOTIVO_ADMIN: …". Vale o motivo dos dados (o Mover já manda) ou o que a tela
--      preparou nos últimos 5 minutos (porta_motivo_preparar) — sem mudar a assinatura de nenhuma função de botão.
--  (2) porta_motivos: o motivo preparado (quem, quando, em que evento foi usado).
--  (3) porta_sombra.motivo: o motivo fica gravado junto do evento (o "diário" da porta), via _porta_anotar.
-- A tela (app.js) pega o "MOTIVO_ADMIN", pergunta o motivo, chama porta_motivo_preparar e repete a mesma ação — vale para todos os
-- botões de todas as telas. A extensão mostra a frase; o admin faz pela ficha.
-- Recriadas da versão no ar: porta (md5 9d3c6d5f…) e _porta_anotar (md5 31457319…) = produção.
-- Regra 20: (1)–(2) sem estado novo; (3) toda ação de admin com autor E motivo; (4) sem fonte nova; (5) cenário X32 + os cenários de
-- admin (X4, X7, X18, X20…) passam a dar o motivo. Guia: o admin passa a escrever o motivo. Desempenho: 1 leitura só nas ações de admin.
begin;

alter table public.porta_sombra add column if not exists motivo text;

create table if not exists public.porta_motivos (
  id         bigserial primary key,
  parceiro_id text not null default 'dharma',
  por        uuid not null,
  motivo     text not null,
  criado_em  timestamptz not null default now(),
  usado_em   timestamptz,
  evento     text
);
create index if not exists porta_motivos_por on public.porta_motivos (por, id desc) where usado_em is null;
alter table public.porta_motivos enable row level security;
drop policy if exists porta_motivos_ler on public.porta_motivos;
create policy porta_motivos_ler on public.porta_motivos for select to authenticated
  using ((select public.meu_perfil()) = 'admin');
revoke all on public.porta_motivos from anon, authenticated;
grant select on public.porta_motivos to authenticated;

create or replace function public.porta_motivo_preparar(p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m text := left(btrim(coalesce(p_motivo, '')), 500);
begin
  if coalesce((select public.meu_perfil()), '') <> 'admin' then
    raise exception 'Só o admin.' using errcode = '42501';
  end if;
  if length(m) < 5 then raise exception 'Escreva o motivo (pelo menos 5 letras).' using errcode = 'P0001'; end if;
  insert into public.porta_motivos (por, motivo) values (auth.uid(), m);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.porta_motivo_preparar(text) from public, anon;
grant execute on function public.porta_motivo_preparar(text) to authenticated;

CREATE OR REPLACE FUNCTION public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  v       public.vendas;
  r       record;
  antes   text;
  fam     text := split_part(coalesce(p_evento, ''), ':', 1);
  arg     text := nullif(split_part(coalesce(p_evento, ''), ':', 2), '');
  cliente boolean := p_evento = 'cliente_escreveu';
  quem    text;
  v_opt   timestamptz;
  res     jsonb;
  ged     text;
  saidas  jsonb := '{"perdida": "recusou", "recusou": "recusou", "fora_area": "cidade_nao_atendida", "sem_cobertura": "fachada_nao_atendida",
                     "ja_cliente": "ja_cliente_nio", "ja_cliente_nio": "ja_cliente_nio", "credito_negado": "credito_negado",
                     "sem_resposta": "sem_resposta", "teste_duplicada": "teste_duplicada"}'::jsonb;   -- silenciar:<motivo antigo> → motivo de Saída
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa for update;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()),
                   case when cliente then 'o cliente' when auth.role() = 'service_role' then 'o sistema' else 'alguém do time' end);

  -- a tabela manda: recusa com a frase, ou segue
  antes := public._porta_situacao(c.id, v.id);
  select * into r from public.porta_prever(antes, p_evento);
  -- 0287: botão da ficha (momento) e Mover do admin sem regra na tabela passam (como o _porta_conferir fazia) — a casca anota o buraco
  if r.aceito is false or (r.aceito is null and fam not in ('momento', 'mover_admin')) then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  -- 0298 (fase 2, passo 6 — D11, D15, E7: "só admin, com motivo"): ação que só o admin faz exige o motivo. Vale o que veio nos dados
  -- (Mover do admin) ou o que a tela preparou há pouco (porta_motivo_preparar). Sem motivo, a tela pede e repete (MOTIVO_ADMIN).
  if r.exige = 'admin' then
    declare v_mot text := btrim(coalesce(p_dados ->> 'motivo', ''));
            v_mid bigint;
    begin
      if length(v_mot) < 5 then
        select pm.id, pm.motivo into v_mid, v_mot from public.porta_motivos pm
         where pm.por = auth.uid() and pm.usado_em is null and pm.criado_em > now() - interval '5 minutes'
         order by pm.id desc limit 1;
        if v_mid is not null then
          update public.porta_motivos set usado_em = now(), evento = p_evento where id = v_mid;
        end if;
      end if;
      if length(btrim(coalesce(v_mot, ''))) < 5 then
        raise exception 'MOTIVO_ADMIN: %', coalesce(r.frase, 'Esta ação é só do admin') || ' — escreva o motivo (pelo menos 5 letras).'
          using errcode = 'P0001';
      end if;
      perform set_config('porta.motivo', left(btrim(v_mot), 500), true);
    end;
  end if;
  if r.exige = 'ged_sem_leitura' and coalesce(public.meu_perfil(), '') <> 'admin' then   -- 0272, trazido do _porta_conferir (0287)
    ged := public._ged_fresco(v.id);
    if ged is not null then raise exception '%', r.frase || ' (GED360: ' || ged || ')'; end if;
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
  end if;

  -- 0282 (reta final 5): Assumir, Devolver para a Mari e o "assumir antes" do Responder são executados aqui. Não mudam o
  -- destino do lead, então rodam SEM porta.aplicando: os gatilhos antigos do funil seguem calculando etapa e handoff como antes.
  -- 0287: os botões da venda (momento:*) também — viabilidade, crédito, pedido, biometria, OS, agendar, parar. Eles mudam a venda e
  -- o destino sai dos gatilhos de sempre (_funil_venda_mudou → _funil_antes), por isso também rodam SEM porta.aplicando.
  if p_evento = 'time_respondeu' then
    return public._porta_assumir(c, v, coalesce(p_dados, '{}'::jsonb) || jsonb_build_object('via', 'responder'));
  elsif fam = 'momento' then
    -- mesmos argumentos que o núcleo recebeu (venda e/ou conversa), para a peça achar a mesma conversa de antes
    return public._porta_momento(p_venda, arg, coalesce(p_dados, '{}'::jsonb)
             || case when p_conversa is not null then jsonb_build_object('conversa_id', p_conversa) else '{}'::jsonb end);
  elsif fam = 'mover_admin' then   -- 0288: o Mover do admin (a venda muda; o destino sai do gatilho vendas_porta)
    return public._porta_mover(v, arg, coalesce(p_dados, '{}'::jsonb));
  end if;

  perform set_config('porta.aplicando', '1', true);   -- os gatilhos antigos do funil não decidem por cima da porta
  if fam = 'saida' then
    res := public._porta_sair(c, v, arg, p_dados, quem, true);
  elsif fam = 'silenciar' and arg = 'suporte_nio' then
    res := public._porta_silenciar(c, quem, false);
  elsif fam = 'silenciar' and arg = 'reativar' then
    res := public._porta_reativar(c, quem);
  elsif fam = 'silenciar' and saidas ? arg then
    res := public._porta_sair(c, v, saidas ->> arg, p_dados, quem, false);
  elsif fam = 'reabrir' then
    res := public._porta_reabrir(c, v, quem, false, coalesce(c.nao_contatar, false));
  elsif fam = 'nao_contatar' then
    res := public._porta_nao_contatar(c, v, p_dados ->> 'origem');
  elsif fam = 'prazo' and arg = 'esperando_fechar' then          -- 0266 (C10)
    res := public._porta_esperando_fechar(c);
  elsif fam = 'prazo' and arg = 'handoff_sem_resposta' then      -- 0266 (C4)
    res := public._porta_handoff_devolver(c);
  elsif cliente and p_dados ->> 'acao' = 'fim_espera' and antes = 'em_espera' then   -- 0266 (C11)
    res := public._porta_fim_espera(c);
  elsif fam = 'cliente_escreveu' and arg = 'sem_cobertura' then   -- 0279 (caso Felix): Saída por cobertura não reabre
    res := public._porta_volta_sem_cobertura(c, p_dados ->> 'texto');
  elsif cliente and p_dados ->> 'acao' = 'reabrir' and antes = 'saida_pode_voltar' then
    res := public._porta_reabrir(c, v, quem, true, false);
  elsif cliente and p_dados ->> 'acao' = 'silenciar' and antes = 'cliente_nio' then
    res := public._porta_silenciar(c, quem, true);
  else
    perform set_config('porta.aplicando', '', true);
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes); end if;
    raise exception 'Evento ainda não passa pela porta: %', p_evento;
  end if;
  perform set_config('porta.aplicando', '', true);
  return res;
end $function$;

CREATE OR REPLACE FUNCTION public._porta_anotar(p_evento text, p_origem text, p_conversa uuid, p_venda uuid, p_antes text, r jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ls record; p record; d text;
begin
  select l.situacao, l.conversa_id, l.venda_id into ls from public.v_lead_situacao l
   where (p_conversa is not null and l.conversa_id = p_conversa) or (p_venda is not null and l.venda_id = p_venda)
   limit 1;
  d := coalesce(ls.situacao, case when p_conversa is null and p_venda is null then '(novo)' else '(sem situação)' end);
  select * into p from public.porta_prever(p_antes, p_evento);
  insert into public.porta_sombra (evento, origem, conversa_id, venda_id, antes, depois, aceito, para, frase, regra, concorda,
                                   sistema_ok, sistema_resumo, por, motivo)
  values (p_evento, p_origem, coalesce(ls.conversa_id, p_conversa), coalesce(ls.venda_id, p_venda), p_antes, d,
          p.aceito, p.para, p.frase, p.regra,
          case when p.aceito is null then null
               when p.aceito then public._porta_bate(p_antes, d, p.para)
               else d is not distinct from p_antes end,
          coalesce((r ->> 'ok')::boolean, true), left(coalesce(r ->> 'resumo', r ->> 'erro', r ->> 'status'), 300), auth.uid(),
          nullif(current_setting('porta.motivo', true), ''));   -- 0298: o motivo da ação do admin
exception when others then
  null;   -- a sombra nunca derruba o evento
end $function$;

commit;
