-- NIOGEN | supabase/migrations/0446_alerta_golpe_na_os.sql | 28/11/2026 — Claude Code / Fable 5.2
-- Ricardo, 28/11 (cliente recebeu, minutos depois de a OS ser gerada, mensagem de um número DDD 62 com a marca da Nio: "rede sem
-- portas, instalação só em 35 dias, instalamos já por outra operadora, responda 1 ou 2"): "precisamos ser mais contundentes,
-- talvez citando mensagens desse DDD 62, porque uma hora o cliente vai acreditar e cancelar nossa venda" · "Pode seguir dessa
-- forma, mas eu acho que o texto tá muito longo" · "Poucas linhas".
-- Medido na produção em 28/11: o bo_alerta_golpe (0366) só saía depois da confirmação da INSTALAÇÃO e com a janela aberta —
-- 3 envios para 10 vendas com OS; no caso de hoje o alerta chegou 5 min antes do golpe, por sorte da agenda.
--  1) texto novo, curto, que descreve o golpe de hoje e cita o DDD 62 (como exemplo: "geralmente");
--  2) o alerta passa a sair quando a OS é GRAVADA na venda (gatilho adiado para o fim da transação: entra na fila depois do
--     aviso do pedido), uma vez por conversa; o gatilho da confirmação da instalação (0366) continua como segunda chance para
--     quem estava com a janela fechada na hora da OS — nunca repete;
--  3) uma vez, agora: quem tem OS, ainda não instalou, está com a janela aberta e nunca recebeu o alerta recebe o texto novo
--     (só entre 9h e 21h de Brasília);
--  4) a resposta rápida do time "Alerta de golpe" ganha o texto novo, se ninguém a editou.
-- Regra 20: (1) nenhuma situação nova; vez e prazo seguem os da venda · (2) nenhum estado muda — só um aviso · (3) nada de
-- status: a consequência é uma linha na fila chatwoot_acoes · (4) fonte da OS: a venda (porta, extensão, operador) · (5) cenário
-- X168; a fila já é conferida (R3, R7). Regra de ouro 6: aviso da venda — sai com pessoa na conversa (em nome dela, pelo
-- _bo_mensagem); Saída e Não contatar barram; nunca repetido; janela fechada não vira pendência de "mandar à mão".
-- Desempenho: sem impacto em tela (nenhuma view ou função de tela tocada). Medir em 7 dias: vendas com OS × alertas enviados
-- (hoje 3 de 10 → perto de todas com janela aberta) e relatos de cliente sobre o golpe antes/depois do alerta.

begin;

-- 1. texto
update public.config_mari_textos
   set texto = $t$🚨 *Atenção, golpe!* Se chegar mensagem de *outro número* (geralmente DDD 62) dizendo que o seu pedido da Nio não deu certo, que vai demorar ou oferecendo outra operadora, *é golpe*. Não responda, bloqueie o número e me avise aqui. Seu pedido segue normal ✅$t$
 where chave = 'bo_alerta_golpe';

update public.config_respostas_rapidas
   set texto = $t$🚨 *Atenção, golpe!* Mensagem de *outro número* (geralmente DDD 62) dizendo que o seu pedido da Nio não deu certo, que vai demorar ou oferecendo outra operadora *é golpe*. Não responda, bloqueie o número e me avise aqui. Seu pedido segue normal ✅$t$
 where rotulo ilike 'Alerta de golpe%' and texto like '%TIM, Claro ou Vivo%';

-- 2. a peça única do alerta: as travas da 0366, para os dois gatilhos e para o envio único de hoje
create or replace function public._golpe_alerta(c public.mari_conversas, p_venda uuid, p_momento text, p_rotulo text)
returns text language plpgsql security definer set search_path = public as $$
declare v_status text; r jsonb;
begin
  if c.id is null then return 'sem conversa'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%'
     or coalesce(c.nao_contatar, false) then return 'sem canal ou não contatar'; end if;
  if c.saida_motivo is not null or c.quadro_encerrada_motivo is not null
     or (c.funil_destino is not null and c.funil_destino not in ('em_andamento')) then return 'em Saída'; end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select status into v_status from public.vendas where id = coalesce(p_venda, c.venda_id);
    if coalesce(v_status, '') = 'saida' then return 'em Saída'; end if;
  end if;
  -- janela de 24 h fechada: o alerta não vira pendência de "mandar à mão" (a confirmação da instalação tenta de novo).
  if c.ultima_msg_lead_at is null or now() >= c.ultima_msg_lead_at + interval '23 hours' then return 'janela fechada'; end if;
  -- uma vez por conversa
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = c.id and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'bo_alerta_golpe'
                and a.status in ('pendente', 'executando', 'feita')) then return 'já avisado'; end if;
  r := public._bo_mensagem(gen_random_uuid(), 1, p_momento, coalesce(p_venda, c.venda_id), c, 'bo_alerta_golpe', '{}'::jsonb,
                           null, null, p_rotulo);
  return coalesce(r ->> 'status', '?');
end $$;
revoke all on function public._golpe_alerta(public.mari_conversas, uuid, text, text) from public, anon, authenticated;

-- 2a. gatilho da confirmação da instalação (0366): mesma regra, agora pela peça única — segunda chance, nunca repete
create or replace function public._golpe_avisar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._golpe_alerta(new, new.venda_id, 'agendar', 'alerta de golpe (depois da instalação)');
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (new.id, '0366 · alerta de golpe', sqlerrm, jsonb_build_object('instalacao_avisada_em', new.instalacao_avisada_em));
  return null;
end $$;
revoke all on function public._golpe_avisar() from public, anon, authenticated;

-- 2b. gatilho novo: OS gravada na venda. Adiado para o fim da transação — a porta grava a OS ANTES de pôr o aviso do pedido
--     na fila; assim o alerta entra depois dele (id maior = sai depois).
create or replace function public._golpe_avisar_venda()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  if tg_op = 'UPDATE' and old.nio_os is not distinct from new.nio_os then return null; end if;
  select * into c from public.mari_conversas where venda_id = new.id and canal = 'whatsapp' order by created_at desc limit 1;
  perform public._golpe_alerta(c, new.id, 'os', 'alerta de golpe (pedido aberto)');
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (c.id, '0446 · alerta de golpe na OS', sqlerrm, jsonb_build_object('venda_id', new.id));
  return null;
end $$;
revoke all on function public._golpe_avisar_venda() from public, anon, authenticated;

drop trigger if exists vendas_golpe_aviso on public.vendas;
create constraint trigger vendas_golpe_aviso after insert or update of nio_os on public.vendas
  deferrable initially deferred
  for each row when (new.nio_os is not null and new.status <> 'saida')
  execute function public._golpe_avisar_venda();

-- 3. uma vez, agora: quem já tem OS, ainda não instalou e nunca recebeu o alerta (as travas são as da peça única).
--    Varredura automática → só no horário dos toques (9h–21h de Brasília).
do $$
declare x record; v_res text; n int := 0;
begin
  if extract(hour from now() at time zone 'America/Sao_Paulo') not between 9 and 20 then
    raise notice '0446: fora do horário dos toques — envio único não feito';
    return;
  end if;
  for x in
    select v.id as venda_id, c as conv
      from public.vendas v
      join public.mari_conversas c on c.id = (select m.id from public.mari_conversas m where m.venda_id = v.id and m.canal = 'whatsapp'
                                               order by m.created_at desc limit 1)
     where v.nio_os is not null and v.status in ('1_vendido', '2_aguardando_instalacao')
  loop
    v_res := public._golpe_alerta(x.conv, x.venda_id, 'os', 'alerta de golpe (envio único 0446)');
    if v_res = 'pendente' then n := n + 1; end if;
  end loop;
  raise notice '0446: alerta de golpe enviado a % venda(s) com OS ainda não instalada', n;
end $$;

commit;
