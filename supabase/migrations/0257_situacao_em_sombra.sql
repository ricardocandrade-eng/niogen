-- NIOGEN | supabase/migrations/0257_situacao_em_sombra.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 4 do caminho (porta única), 1ª parte — Ricardo, 17/11: "Sim" (travas, prazos e "em seguida começar o passo 4").
-- SÓ LEITURA: nada aqui grava estado nem manda no Chatwoot. Cria:
--   (1) config_situacao — a lista fechada das 15 situações (seção 6 do diagnóstico, G-1), com vez, Chatwoot, Mari e lembretes
--       como DOCUMENTO do destino (as consequências passam a ser executadas por ela no passo 5). Ajustes de 17/11 anotados.
--   (2) lead_situacao(...) — classifica um lead numa situação a partir do que a escada (v_leads) já calcula.
--   (3) v_lead_situacao — a situação de cada lead, "em sombra", ao lado do sistema de hoje.
-- A situação 3 ("com o time, esperando o cliente") ainda não é derivável: nasce com a regra C10 (porta única).
-- Não contatar com venda viva (decisão H1, 0252) não é situação: é a marca "sem_mensagens" sobre a situação da venda.
-- Regra 20: nenhum estado novo. Portão: regra geral R8 "todo lead tem exatamente uma situação da lista".
begin;

create table if not exists public.config_situacao (
  codigo     text primary key,
  numero     int  not null unique,
  nome       text not null,
  vez        text not null,
  chatwoot   text not null,
  mari       text not null,
  lembretes  text not null,
  nota       text
);
alter table public.config_situacao enable row level security;
drop policy if exists config_situacao_ler on public.config_situacao;
create policy config_situacao_ler on public.config_situacao for select to authenticated using (true);
grant select on public.config_situacao to authenticated;

insert into public.config_situacao (codigo, numero, nome, vez, chatwoot, mari, lembretes, nota) values
  ('mari_atendendo',         1, 'Mari atendendo',                       'Mari ou cliente', 'aberta, sem dono',              'sim',                          'cadência de lead', null),
  ('time_agora',             2, 'Com o time — responder agora',         'time',            'aberta, time',                  'não',                          'nenhum', 'inclui "Pediu uma pessoa" (30 min, 0256), conferir 200 m e antifraude'),
  ('time_esperando',         3, 'Com o time — esperando o cliente',     'cliente',         'resolvida, com dono guardado',  'não',                          'o que o time marcar', 'ainda não derivável: nasce com a regra C10 na porta única'),
  ('em_espera',              4, 'Em espera (com data e motivo)',        'quem destrava',   'adiada',                        'não',                          'nenhum até a data', null),
  ('qualificado_credito',    5, 'Qualificado — rodar crédito',          'time',            'conforme a vez',                'conforme a vez',               '—', 'vez = próxima tarefa (C8, 17/11): devolver à Mari passa só a conversa'),
  ('qualificado_biometria',  6, 'Qualificado — aguarda biometria',      'cliente',         'conforme o dono',               'só se o cliente escrever',     'biometria (sai mesmo com o time — 0253)', null),
  ('qualificado_os',         7, 'Qualificado — gravar venda (OS)',      'time, 4 h',       'aberta, time',                  'não',                          '—', 'OS só com biometria aprovada (0256)'),
  ('instalacao_agendar',     8, 'Instalação — agendar ou remarcar',     'time, 4 h',       'aberta, time',                  'não',                          '—', 'inclui "Pediu para remarcar" (0256)'),
  ('instalacao_aguardando',  9, 'Instalação — aguardando (Nio)',        'Nio',             'fica com quem estava (0254)',   'pós-venda, se escrever',       'aviso, véspera, cartão', 'era "resolvida": desde 0254 o agendar não resolve'),
  ('instalacao_pendencia',  10, 'Instalação — pendência',               'quem o código indicar', 'conforme a vez',          'não',                          '—', 'inclui a defesa da Nio'),
  ('instalada',             11, 'Instalada',                            'ninguém',         'resolvida',                     'pós-instalação e indicação',   'pós-instalação, régua de pagamento', null),
  ('saida_pode_voltar',     12, 'Saída — pode voltar',                  'ninguém',         'resolvida, sem dono',           'só se o cliente escrever (reabre)', 'nenhum; volta na data', null),
  ('saida_definitiva',      13, 'Saída — definitiva',                   'ninguém',         'resolvida, sem dono',           'resposta curta, sem venda',    'nenhum', 'crédito, biometria, Nio não instalou, fraude, teste'),
  ('nao_contatar',          14, 'Não contatar',                         'ninguém',         'resolvida, sem dono',           'nunca',                        'nenhum, nem os da venda', 'só sem venda viva; com venda viva a venda segue sem mensagens (H1, 0252)'),
  ('cliente_nio',           15, 'Cliente Nio / suporte',                'ninguém',         'resolvida',                     'indica o App Nio',             'nenhum', null)
on conflict (codigo) do update set numero = excluded.numero, nome = excluded.nome, vez = excluded.vez, chatwoot = excluded.chatwoot,
  mari = excluded.mari, lembretes = excluded.lembretes, nota = excluded.nota;

create or replace function public.lead_situacao(p_status text, p_destino text, p_saida_motivo text, p_em_espera boolean, p_vez text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_destino = 'instalada' then 'instalada'
    when p_destino = 'teste_duplicada' then 'saida_definitiva'
    when p_destino = 'saida' then case
      when p_saida_motivo = 'nao_contatar' then 'nao_contatar'
      when p_saida_motivo = 'ja_cliente_nio' then 'cliente_nio'
      when p_saida_motivo in ('credito_negado', 'reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude', 'teste_duplicada') then 'saida_definitiva'
      when p_saida_motivo in ('recusou', 'sem_resposta', 'fachada_nao_atendida', 'cidade_nao_atendida') then 'saida_pode_voltar'
      end
    when p_destino = 'em_andamento' then case
      when coalesce(p_em_espera, false) then 'em_espera'
      when p_status in ('pendencia_nio', 'defesa_nio') then 'instalacao_pendencia'
      when p_status in ('aguardando_instalacao', 'aguarda_cartao') then 'instalacao_aguardando'
      when p_status in ('agendar', 'remarcar') then 'instalacao_agendar'
      when p_status = 'abrir_os' then 'qualificado_os'
      when p_status = 'aguarda_biometria' then 'qualificado_biometria'
      when p_status in ('rodar_credito', 'fazer_pedido') then 'qualificado_credito'
      when p_status in ('pediu_humano', 'conferir_200m', 'antifraude_conferir') then 'time_agora'
      when p_status in ('nova', 'respondeu', 'consultando_cep', 'viu_planos') then case when p_vez = 'time' then 'time_agora' else 'mari_atendendo' end
      end
    end
$$;

create or replace view public.v_lead_situacao with (security_invoker = true) as
select l.lead_id, l.conversa_id, l.venda_id, l.nome,
       public.lead_situacao(l.status, l.destino, l.saida_motivo, l.em_espera, l.vez) as situacao,
       s.numero as situacao_numero, s.nome as situacao_nome,
       l.status, l.destino, l.saida_motivo, l.vez, l.prazo_em, l.em_espera,
       (coalesce(c.nao_contatar, false) and l.destino = 'em_andamento') as sem_mensagens
  from public.v_leads l
  left join public.mari_conversas c on c.id = l.conversa_id
  left join public.config_situacao s on s.codigo = public.lead_situacao(l.status, l.destino, l.saida_motivo, l.em_espera, l.vez);
grant select on public.v_lead_situacao to authenticated;

commit;
