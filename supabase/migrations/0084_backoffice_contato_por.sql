-- NIOGEN | supabase/migrations/0084_backoffice_contato_por.sql | 09/11/2026 — Claude Code
-- Prova da 0082: contatos_cliente.por só aceita mari/vendedor/cliente (check contatos_cliente_por_check). A mensagem do
-- backoffice saiu (entregue), mas o registro do resultado falhava com por = 'backoffice'. O contato do time é 'vendedor'
-- (o mesmo do "Registrar contato" da ficha); o toque BO_<MOMENTO> e o resumo "NIOGEN · …" dizem de onde veio.

create or replace function public.backoffice_acao_resultado(p_id bigint, p_ok boolean, p_erro text default null)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  select * into a from public.chatwoot_acoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'ação inexistente'); end if;
  if not coalesce(p_ok, false) then
    update public.chatwoot_acoes
       set status = case when tentativas >= 3 then 'erro' else 'pendente' end,
           executar_apos = case when tentativas >= 3 then executar_apos else now() + interval '2 minutes' end,
           erro = left(coalesce(p_erro, 'sem detalhe'), 500)
     where id = p_id;
    if a.tentativas >= 3 then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (a.conversa_id, 'backoffice_chatwoot', 'ação ' || a.tipo || ' (' || a.momento || ') falhou 3×: ' || left(coalesce(p_erro, ''), 300),
              jsonb_build_object('acao_id', a.id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;
  update public.chatwoot_acoes set status = 'feita', erro = null, feita_em = now() where id = p_id;
  if a.tipo = 'mensagem' then
    select * into c from public.mari_conversas where id = a.conversa_id;
    -- Conta no teto do contrato (2/dia · 15/mês) e aparece no histórico da conversa como fala da Mari (o bot assina).
    insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_' || upper(a.momento), 'ativo',
            'NIOGEN · ' || coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' · template ' || (a.payload ->> 'template'), ''));
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (a.conversa_id, 'mari', coalesce(a.payload ->> 'content', ''), jsonb_build_object('backoffice', a.momento, 'acao_id', a.id), now());
  end if;
  return jsonb_build_object('ok', true, 'registrado', 'feita');
end;
$$;
create or replace function public.backoffice_acao_manual(p_id bigint, p_enviei boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into a from public.chatwoot_acoes where id = p_id and status = 'bloqueada' for update;
  if not found then raise exception 'Esta linha já saiu da Fila.'; end if;
  update public.chatwoot_acoes set status = case when p_enviei then 'manual' else 'cancelada' end, feita_em = now() where id = p_id;
  if p_enviei then
    select * into c from public.mari_conversas where id = a.conversa_id;
    insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_' || upper(a.momento), 'ativo',
            'enviado à mão pelo Chatwoot · ' || coalesce(a.payload ->> 'rotulo', a.momento));
  end if;
  if a.venda_id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (a.venda_id, 'backoffice', jsonb_build_object('momento', a.momento,
            'resumo', case when p_enviei then '✓ mensagem enviada à mão' else 'mensagem descartada' end), auth.uid());
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
