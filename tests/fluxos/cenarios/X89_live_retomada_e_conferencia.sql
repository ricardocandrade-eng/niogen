-- id: X89
-- titulo: 0363 (23/11): lead com a Retomada aberta não cai em "Sem caixa"; "nada a responder" tira o cliente de "esperando nós" na conferência; aviso da venda com a conversa assumida não acusa "fala por cima", mensagem comum acusa
-- tipo: atual
select sim.como('servico');

-- 1) Retomada aberta = a Mari ainda vai falar (D7) → caixa 1, não 5. Fechou a Retomada e não há toque → volta a ser 5.
select sim.lead_novo('Thiago X89') as a \gset
update public.mari_conversas
   set ultima_msg_lead_at = now() - interval '3 days', ultima_msg_mari_at = now() - interval '6 hours',
       cadencia_proximo_em = null, cadencia_passo = 'F3', retomada_desde = now() - interval '6 hours', retomada_passo = 'D3',
       retomada_passo_em = now() - interval '6 hours', retomada_fim = null, retomada_fim_em = null, status = 'ativo'
 where id = :'a';
select caixa as cx_aberta, o_que_fazer as of_aberta from public.v_jornada where conversa_id = :'a' \gset
select sim.confere('Retomada aberta: Mari conduzindo (caixa 1), fora do Para fazer', :cx_aberta = 1, :cx_aberta || ' · ' || :'of_aberta');
update public.mari_conversas set retomada_fim = 'sem_resposta', retomada_fim_em = now() where id = :'a';
select caixa as cx_fechada, o_que_fazer as of_fechada from public.v_jornada where conversa_id = :'a' \gset
-- (o texto aqui é o do alerta "parado", que vem antes; o da caixa 5 vale quando não há alerta — conferido na definição)
select sim.confere('Retomada fechada e sem toque: Sem caixa, sem prometer o "devolva com retorno" que não existe',
  :cx_fechada = 5 and :'of_fechada' not like '%com retorno%', :cx_fechada || ' · ' || :'of_fechada');
select sim.confere('o texto da caixa 5 aponta a saída que existe (⏸ Aguardar)',
  pg_get_viewdef('public.v_jornada'::regclass) like '%ponha em ⏸ Aguardar com data ou dê Saída%'
    and pg_get_viewdef('public.v_jornada'::regclass) not like '%devolva à Mari com retorno%', 'texto antigo');

-- 2) Cliente escreveu por último → "esperando nós". O time marca "nada a responder" → sai da conta.
select sim.lead_novo('Cintia X89') as b \gset
select sim.cliente_escreve(:'b', 'Confirmo', false, '1 minute');
select caixa as f_antes from public.v_atendimento_fatos where conversa_id = :'b' \gset
select sim.confere('cliente escreveu e ninguém respondeu: esperando nós', :'f_antes' = 'esperando_nos', :'f_antes');
select sim.como('admin');
select public.backoffice_conversa_dispensar(:'b');
select sim.como('servico');
select caixa as f_depois from public.v_atendimento_fatos where conversa_id = :'b' \gset
select sim.confere('"nada a responder" marcado depois da fala: não é mais esperando nós', :'f_depois' <> 'esperando_nos', :'f_depois');
select sim.cliente_escreve(:'b', 'Que horas o técnico vem?', false, '1 minute');
select caixa as f_volta from public.v_atendimento_fatos where conversa_id = :'b' \gset
select sim.confere('cliente escreveu de novo depois do "nada a responder": volta a esperando nós', :'f_volta' = 'esperando_nos', :'f_volta');

-- 3) Conversa assumida: aviso da venda (INSTALACAO) depois da fala do cliente não acusa; mensagem automática comum acusa.
select sim.lead_novo('Cris X89') as c \gset
select chatwoot_conversation_id as cw_c, nome_contato as nome_c from public.mari_conversas where id = :'c' \gset
insert into public.chatwoot_acoes (grupo, momento, conversa_id, chatwoot_conversation_id, tipo, payload, status, criada_em)
values (gen_random_uuid(), 'assumir', :'c', :'cw_c', 'atribuir', '{"assignee_id": 1}'::jsonb, 'feita', now() - interval '2 hours');
insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags, created_at)
values (:'c', 'lead', 'ok', false, '{}'::jsonb, now() - interval '90 minutes'),
       (:'c', 'mari', 'Sua instalação está agendada', false, '{"cadencia": "INSTALACAO", "simulado": true}'::jsonb, now() - interval '80 minutes');
select x ->> 'texto' as t_aviso from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'msg_auto_assumida' \gset
select sim.confere('aviso da instalação com a conversa assumida: não acusa "fala por cima"', :'t_aviso' not like ('%' || :'nome_c' || '%'), :'t_aviso');
insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags, created_at)
values (:'c', 'lead', 'e o preço?', false, '{}'::jsonb, now() - interval '30 minutes'),
       (:'c', 'mari', 'O plano sai R$ 110', false, '{}'::jsonb, now() - interval '29 minutes');
select x ->> 'texto' as t_comum, x ->> 'nivel' as n_comum from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'msg_auto_assumida' \gset
select sim.confere('a Mari respondendo com a conversa assumida: acusa (falha)', :'t_comum' like ('%' || :'nome_c' || '%') and :'n_comum' = 'falha', :'t_comum');
