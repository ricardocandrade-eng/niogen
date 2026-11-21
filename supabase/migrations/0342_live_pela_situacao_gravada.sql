-- NIOGEN | supabase/migrations/0342_live_pela_situacao_gravada.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Fase 2, passo 4b (d) — debate da Live com o Ricardo (21/11, madrugada):
--   1. "Sim, pela vez do time": o Para fazer da Sua fila = leads com a vez do time na situação gravada pela porta (lead_estado),
--      na ordem do prazo gravado — troca direta, sem sombra.
--   2. "Sim, as 15": a coluna Situação mostra o nome das 15 situações (config_situacao).
--   3. "Sim, da situação": o "o que fazer" e o botão vêm da situação gravada; os textos finos da v_jornada seguem valendo.
--   4. "Ficam como estão": Conferir, Andamento na Nio, 🔥 e Radar não mudam.
--   + "Para fazer, como alarme": os ~12 alarmes da v_jornada que puxam o time com a vez gravada sendo da Nio, do cliente ou da Mari
--     (visita hoje sem cartão, Nio não deu baixa, mensagem não saiu, janela fechando, sem caixa…) continuam no Para fazer.
-- O que muda aqui: config_situacao ganha o texto e o botão de cada situação; live_situacoes() devolve a situação gravada de cada
-- lead (uma leitura da tabela, ~ms) para a Live montar o Para fazer e a coluna. A tela (fila.html) vai no mesmo commit.
-- Regra 20: (1) duas colunas de configuração, escritas só aqui; (2) nenhum estado novo — a Live só LÊ o que a porta grava;
--     (3) tela: Live (debatida, 4 decisões acima); (4) sem fonte nova; (5) desempenho: 1 chamada leve na carga da Live. Cenário X67.
begin;

alter table public.config_situacao
  add column if not exists o_que_fazer text,
  add column if not exists botao text;
comment on column public.config_situacao.o_que_fazer is '0342: o que o time faz nesta situação (texto da Live quando não há alarme mais específico)';
comment on column public.config_situacao.botao is '0342: botão da linha da Live nesta situação (responder · abrir)';

update public.config_situacao s set o_que_fazer = x.t, botao = x.b
  from (values
    ('mari_atendendo',        'A Mari está atendendo',                                        'abrir'),
    ('time_agora',            'Responder o cliente',                                          'responder'),
    ('time_esperando',        'Esperando o cliente responder',                                'abrir'),
    ('em_espera',             'Em espera · revisar na data combinada',                        'abrir'),
    ('qualificado_credito',   'Rodar o crédito no portal',                                    'abrir'),
    ('qualificado_biometria', 'Esperando a biometria do cliente',                             'abrir'),
    ('qualificado_os',        'Gravar a venda: OS e data da instalação',                      'abrir'),
    ('instalacao_agendar',    'Agendar ou remarcar a instalação no portal e gravar',          'abrir'),
    ('instalacao_aguardando', 'Aguardando a Nio instalar',                                    'abrir'),
    ('instalacao_pendencia',  'Resolver a pendência da Nio',                                  'abrir'),
    ('instalada',             'Instalada',                                                    'abrir'),
    ('saida_pode_voltar',     'Saída · se o cliente escrever, a Mari responde',               'abrir'),
    ('saida_definitiva',      'Saída definitiva',                                             'abrir'),
    ('nao_contatar',          'Não contatar',                                                 'abrir'),
    ('cliente_nio',           'Cliente Nio · suporte pelo App Nio',                           'abrir')
  ) as x(c, t, b)
 where s.codigo = x.c;

-- a situação gravada de cada lead, para a Live (só admin e backoffice, como a jornada_live)
create or replace function public.live_situacoes()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'conversa_id', e.conversa_id, 'venda_id', e.venda_id, 'situacao', e.situacao, 'nome', s.nome,
             'vez', e.vez, 'prazo_em', e.prazo_em, 'em', e.em, 'o_que_fazer', s.o_que_fazer, 'botao', s.botao))
      from public.lead_estado e
      left join public.config_situacao s on s.codigo = e.situacao), '[]'::jsonb);
end $$;
revoke all on function public.live_situacoes() from public, anon;
grant execute on function public.live_situacoes() to authenticated, service_role;

commit;
