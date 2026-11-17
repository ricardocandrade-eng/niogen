-- NIOGEN | supabase/migrations/0269_porta_botoes.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 6 do caminho (porta única) — Ricardo, 17/11: "Pode começar".
-- Regra de ouro 3: "Botão só existe se o banco aceita aquele evento naquela situação — e mostra, antes do clique, o que vai
-- desencadear." Esta migration dá à tela (ficha, conversa, Live) e à extensão UMA chamada que responde isso para um lead:
--   (1) config_efeito — o que cada evento faz, em português simples (consequência é tabela: a tela nunca escreve esse texto).
--   (2) porta_botoes(conversa, venda) — a situação do lead e, para cada evento de botão, se vale agora (ok), por que não
--       (frase), se pede admin, para onde leva e o "isto vai acontecer" (efeito + o que a situação de destino manda).
-- Só leitura: nenhuma função que muda lead foi tocada; as cascas da 0263 e os núcleos ficam como estão.
-- Segurança: security invoker — o lead só aparece se o RLS de v_lead_situacao deixar (vendedor vê só o dele).
-- Regra 20: (1) usa a situação gravada · (2) não cria estado · (3) não grava nada · (4) fonte única = config_transicao +
-- config_efeito + config_situacao · (5) conferência: regra R13 do portão (porta_botoes concorda com porta_prever em toda situação).
begin;

-- ── (1) o que cada evento faz ──
create table if not exists public.config_efeito (
  evento  text primary key,
  efeito  text not null,
  nota    text
);
alter table public.config_efeito enable row level security;
drop policy if exists config_efeito_ler on public.config_efeito;
create policy config_efeito_ler on public.config_efeito for select to authenticated using (true);
grant select on public.config_efeito to authenticated;

insert into public.config_efeito (evento, efeito) values
  ('momento:assumir',              'Você vira o dono da conversa e a Mari para de responder.'),
  ('momento:devolver_mari',        'A Mari volta a conduzir a conversa e o dono do time é limpo.'),
  ('momento:parar',                'Não contatar: etiqueta nao-contatar, nota e conversa resolvida. Ninguém mais chama este cliente, nem os avisos da venda.'),
  ('nao_contatar',                 'Não contatar: etiqueta nao-contatar, nota e conversa resolvida. Ninguém mais chama este cliente, nem os avisos da venda.'),
  ('momento:viabilidade:*',        'Grava na venda o que o portal respondeu sobre a viabilidade.'),
  ('momento:viabilidade:viavel',   'Grava a viabilidade; o próximo passo é o crédito.'),
  ('momento:credito:*',            'Grava na venda o resultado do crédito.'),
  ('momento:credito:aprovado',     'Grava o crédito aprovado; o próximo passo é a biometria.'),
  ('momento:credito:so_cartao',    'Grava o crédito aprovado só no cartão; o próximo passo é a biometria.'),
  ('momento:credito:negado',       'Grava o crédito negado: o cliente recebe o pedido de outro CPF e abre a pendência "aguardando outro CPF".'),
  ('momento:credito:pendente',     'Grava o crédito como pendente; nova consulta em 24 h.'),
  ('momento:pedido',               'Grava o nº do pedido; etiqueta, nota e aviso ao cliente saem sozinhos.'),
  ('momento:biometria:*',          'Grava o que o GED360 ou o portal mostram da biometria.'),
  ('momento:biometria:validada',   'Marca a biometria como aprovada; o próximo passo é gravar a OS.'),
  ('momento:biometria:dispensada', 'Vale como biometria aprovada (a Nio liberou): a venda segue para a instalação e fica registrado quem marcou.'),
  ('momento:biometria:negado',     'Biometria reprovada: a venda pode ir para Saída definitiva.'),
  ('momento:os',                   'Grava o nº da OS; a venda passa para a instalação.'),
  ('momento:os_agendar',           'Grava a OS e o agendamento; a venda fica aguardando a Nio instalar.'),
  ('momento:agendar',              'Grava o dia e o turno da instalação; a venda fica aguardando a Nio.'),
  ('momento:reagendar',            'Grava a nova data da instalação.'),
  ('saida:*',                      'Saída: grava o motivo e quem deu; ninguém fica com a vez; cadência e lembretes param (inclusive os da venda); Chatwoot resolvida e sem dono; com pedido ou OS aberta, nasce a tarefa "Cancelar na Nio"; a comissão prevista sai da conta.'),
  ('silenciar:*',                  'Saída: grava o motivo e quem deu; ninguém fica com a vez; cadência e lembretes param; Chatwoot resolvida e sem dono.'),
  ('silenciar:suporte_nio',        'Silenciar: cliente Nio pedindo suporte. A Mari não responde mais e a conversa sai da Live; não volta quando ele escrever.'),
  ('silenciar:ja_cliente',         'Já é cliente Nio: a Mari indica os canais oficiais e a conversa sai da Live.'),
  ('silenciar:ja_cliente_nio',     'Já é cliente Nio: a Mari indica os canais oficiais e a conversa sai da Live.'),
  ('silenciar:reativar',           'Reativar: a conversa volta para a Live e a Mari volta a responder.'),
  ('reabrir',                      'Reabrir: sai da Saída e volta para o degrau onde parou. A conversa reabre e a Mari volta a responder.'),
  ('aguardar',                     'Em espera até a data: cadência parada e Chatwoot adiada. No dia, às 9 h, volta para quem pôs a espera; se o cliente escrever antes, a espera acaba.'),
  ('dispensar',                    'Tira o aviso "cliente escreveu" sem responder. A situação não muda.'),
  ('virar_venda',                  'Abre a venda deste lead em Qualificado; aí você grava o pedido, a OS e a agenda.'),
  ('trocar_titular',               'Troca o titular para o CPF de um parente; crédito e biometria voltam a zero.'),
  ('mover_admin:*',                'Move a venda à mão (só o admin), com o autor gravado.'),
  ('antifraude:*',                 'Grava a decisão do antifraude.'),
  ('time_respondeu',               'Você vira o dono e a vez passa ao cliente; a Mari não responde. Se o cliente não voltar em 1 h, a conversa fecha com o dono guardado.'),
  ('time_nota',                    'Nota interna: o cliente não vê e a situação não muda.')
on conflict (evento) do update set efeito = excluded.efeito;

-- o efeito de um evento: o exato, senão a família (momento:credito:* → momento:*), como porta_prever lê a tabela
create or replace function public._efeito_de(p_evento text) returns text language plpgsql stable set search_path = public as $$
declare partes text[] := string_to_array(coalesce(p_evento, ''), ':'); e text; r text;
begin
  select efeito into r from public.config_efeito where evento = p_evento;
  if r is not null then return r; end if;
  for k in reverse coalesce(array_length(partes, 1), 1) - 1 .. 1 loop
    e := array_to_string(partes[1:k], ':') || ':*';
    select efeito into r from public.config_efeito where evento = e;
    if r is not null then return r; end if;
  end loop;
  return null;
end $$;

-- ── (2) os botões de um lead ──
-- Devolve { situacao:{codigo,numero,nome,vez,chatwoot,mari,lembretes}, admin, eventos:{ "<evento>": {ok, aceito, exige,
--   frase, para:[nomes], efeito} } }. "ok" = o botão pode aparecer para QUEM ESTÁ LOGADO (aceito, e o "exige" atendido).
-- Sem regra na tabela (aceito nulo): ok — a porta deixa passar e anota (0268), a tela não esconde.
-- Eventos de robô (nio:*, funil:*, prazo:*), da Mari (mari_passou:*) e do cliente (cliente_escreveu) não são botões: ficam fora.
create or replace function public.porta_botoes(p_conversa uuid default null, p_venda uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  s text; achou boolean := false; conv uuid := p_conversa; sit jsonb; admin boolean;
  ev text; r record; ok boolean; destino text; efeito text; nomes text[]; frase text;
  opt_ok boolean := null; out jsonb := '{}'::jsonb;
begin
  if p_conversa is null and p_venda is null then raise exception 'Informe a conversa ou a venda.'; end if;
  select ls.situacao, ls.conversa_id, true into s, conv, achou from public.v_lead_situacao ls
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
    if r.aceito is not true then frase := coalesce(frase, 'Esta ação não vale nesta situação.'); else frase := case when ok then null else frase end; end if;
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

commit;
