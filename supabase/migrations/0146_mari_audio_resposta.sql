-- NIOGEN | supabase/migrations/0146_mari_audio_resposta.sql | 12/11/2026 — Claude Code
-- docs/Prompt_mari_resposta_audio_121126_1800.md (Ricardo, 12/11: resposta em áudio com OpenAI TTS, voz Marin; cadência F2 com imagem
-- e F3 em voz, com A/B). Tudo nasce DESLIGADO e, ao ligar, só para os telefones de teste (config 'teste').
--   1. mari_midia_envios (parceiro_id — regra 15): cada voz/imagem que a Mari mandou (resposta ou cadência), com o grupo do A/B.
--      É a fonte da medição e da tela da conversa (player do áudio da Mari). Leitura admin/backoffice; escrita só service role.
--   2. mari_midia_registrar(p jsonb): o n8n mari_midia_envio grava o envio.
--   3. config_mari_textos: chaves audio_* / midia_cadencia_* (regra 15 — nada fixo no código).
--   4. mari_cutucada_contexto devolve conversa_id e a imagem do plano (cartão do carrossel) para a cutucada com imagem.

begin;

create table if not exists public.mari_midia_envios (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  conversa_id uuid references public.mari_conversas (id) on delete cascade,
  origem      text not null check (origem in ('resposta', 'cadencia', 'teste')),
  passo       text,
  tipo        text not null check (tipo in ('voz', 'imagem')),
  texto       text,
  caminho     text,
  imagem_url  text,
  ab          text,
  ok          boolean not null default false,
  erro        text,
  wamid       text,
  created_at  timestamptz not null default now()
);
create index if not exists mari_midia_envios_conversa_idx on public.mari_midia_envios (conversa_id, created_at);
alter table public.mari_midia_envios enable row level security;
drop policy if exists mari_midia_envios_ler on public.mari_midia_envios;
create policy mari_midia_envios_ler on public.mari_midia_envios for select to authenticated
  using ((select public.meu_perfil()) = any (array['admin', 'backoffice']));
grant select on public.mari_midia_envios to authenticated;

create or replace function public.mari_midia_registrar(p jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  insert into public.mari_midia_envios (conversa_id, origem, passo, tipo, texto, caminho, imagem_url, ab, ok, erro, wamid)
  values (nullif(p->>'conversa_id', '')::uuid, coalesce(nullif(p->>'origem', ''), 'resposta'), nullif(p->>'passo', ''),
          p->>'tipo', left(p->>'texto', 2000), nullif(p->>'caminho', ''), nullif(p->>'imagem_url', ''), nullif(p->>'ab', ''),
          coalesce((p->>'ok')::boolean, false), left(nullif(p->>'erro', ''), 500), nullif(p->>'wamid', ''))
  returning id into v_id;
  if not coalesce((p->>'ok')::boolean, false) and nullif(p->>'conversa_id', '') is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values ((p->>'conversa_id')::uuid, 'mari_midia_envio', 'mídia não saiu (' || coalesce(p->>'tipo', '?') || '): ' || coalesce(left(p->>'erro', 300), 'sem detalhe'),
            jsonb_build_object('origem', p->>'origem', 'passo', p->>'passo', 'midia_envio_id', v_id));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.mari_midia_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.mari_midia_registrar(jsonb) to service_role;

-- 3 · config (valores em texto, como o resto de config_mari_textos). 'teste' = só os telefones de config 'telefones_teste'; '' = todos.
insert into public.config_mari_textos (chave, texto) values
  ('audio_resposta_ligado', 'nao'),
  ('audio_resposta_telefones', 'teste'),
  ('audio_resposta_voz', 'marin'),
  ('audio_resposta_modelo', 'gpt-4o-mini-tts'),
  ('audio_resposta_instrucoes', 'Atendente brasileira de Minas Gerais, simpática e natural, falando num áudio de WhatsApp com um cliente. Ritmo tranquilo, sem soar locutora nem robô. Fala números por extenso.'),
  ('audio_resposta_max_chars', '350'),
  ('midia_cadencia_ligado', 'nao'),
  ('midia_cadencia_telefones', 'teste'),
  ('audio_cadencia_passo', 'F3'),
  ('imagem_cadencia_passo', 'F2'),
  ('midia_cadencia_ab', 'sim')
on conflict (chave) do nothing;

-- 4 · contexto da cutucada com conversa_id e a imagem do plano
CREATE OR REPLACE FUNCTION public.mari_cutucada_contexto(p_conversa uuid, p_passo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.mari_conversas; v jsonb;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null then return null; end if;
  select jsonb_build_object(
    'conversa_id', c.id,
    'passo', p_passo,
    'numero_da_cutucada', case p_passo when 'F1' then 1 when 'F2' then 2 when 'F3' then 3 when 'F4' then 4 when 'F5' then 5 else 1 end,
    'nome', case when coalesce(c.nome_confiavel, false) then split_part(coalesce(c.dados->>'nome', c.nome_contato, ''), ' ', 1) end,
    'cidade', c.cidade, 'etapa', c.etapa,
    'tem_cep', c.cep is not null, 'tem_numero', c.numero is not null,
    'plano_escolhido', (select p.nome from public.config_planos p where p.codigo = c.plano_escolhido),
    'falta', case when c.plano_escolhido is not null then public.mari_cadencia_campo_falta(c) end,
    'cobertura', c.cobertura_decisao,
    -- 0146: imagem do plano para a cutucada com imagem (cartão do carrossel aprovado; sem plano → o 1º cartão ativo)
    'midia', jsonb_build_object(
      'imagem_url', coalesce((select k.imagem_url from public.config_mari_carrossel k where k.ativo and k.plano_codigo = c.plano_escolhido limit 1),
                             (select k.imagem_url from public.config_mari_carrossel k where k.ativo order by k.ordem limit 1)),
      'plano_da_imagem', coalesce((select p.nome from public.config_planos p join public.config_mari_carrossel k on k.plano_codigo = p.codigo
                                    where k.ativo and k.plano_codigo = c.plano_escolhido limit 1),
                                  (select p.nome from public.config_planos p join public.config_mari_carrossel k on k.plano_codigo = p.codigo
                                    where k.ativo order by k.ordem limit 1))),
    'texto_reserva', public.mari_cadencia_texto(c, p_passo),
    'cutucadas_ja_enviadas', (select coalesce(jsonb_agg(t.texto order by t.created_at), '[]'::jsonb) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel = 'mari' and coalesce(t.tags ->> 'cadencia', '') <> ''
                                 and t.created_at > coalesce(c.ultima_msg_lead_at, c.created_at)),
    'falas', (select coalesce(jsonb_agg(jsonb_build_object('quem', x.papel, 'texto', x.t) order by x.created_at), '[]'::jsonb)
                from (select t.papel, t.created_at, left(public._auditoria_mascarar(t.texto), 300) t from public.mari_turnos t
                       where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')
                       order by t.created_at desc limit 10) x)
  ) into v;
  return v;
end $function$;

notify pgrst, 'reload schema';

commit;
