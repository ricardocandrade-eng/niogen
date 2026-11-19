-- NIOGEN | supabase/migrations/0309_imagem_followup_mari.sql | 19/11/2026 — Claude Code
-- Resumo: a imagem do lembrete da Mari (F2) passa a ser a arte "followup_mari" (Ricardo, 19/11/2026: "Troque a imagem que a Mari
--   envia no followup pelo arquivo mari_followup"), no lugar do cartão do plano do carrossel. A URL fica em config
--   (config_mari_textos.imagem_cadencia_url, regra 15); vazia → volta ao cartão do plano, como na 0146.
--   Arte: docs/assets/mari/followup_mari_191126.jpg (site do NIOGEN), cópia da criativos_nov26/mari_carrossel/followup_mari.png.
--   Cinco regras (regra 20): não cria situação, evento, estado nem tabela — só troca a imagem de uma mensagem que já saía;
--   cada envio continua em mari_midia_envios. Nenhuma conferência nova necessária.
--   Para voltar ao cartão do plano: update config_mari_textos set texto = '' where chave = 'imagem_cadencia_url';
begin;

insert into public.config_mari_textos (chave, texto) values
  ('imagem_cadencia_url', 'https://niogen.dharmatelecom.com.br/assets/mari/followup_mari_191126.jpg')
on conflict (chave) do update set texto = excluded.texto;

CREATE OR REPLACE FUNCTION public.mari_cutucada_contexto(p_conversa uuid, p_passo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.mari_conversas; v jsonb; v_img text;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null then return null; end if;
  -- 0309: arte fixa do lembrete, se configurada
  select nullif(trim(t.texto), '') into v_img from public.config_mari_textos t where t.chave = 'imagem_cadencia_url';
  if v_img is not null and v_img !~ '^https://' then v_img := null; end if;
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
    -- 0309: com imagem_cadencia_url configurada, vai a arte do lembrete (sem plano da imagem)
    'midia', case when v_img is not null then jsonb_build_object('imagem_url', v_img, 'plano_da_imagem', null)
      else jsonb_build_object(
      'imagem_url', coalesce((select k.imagem_url from public.config_mari_carrossel k where k.ativo and k.plano_codigo = c.plano_escolhido limit 1),
                             (select k.imagem_url from public.config_mari_carrossel k where k.ativo order by k.ordem limit 1)),
      'plano_da_imagem', coalesce((select p.nome from public.config_planos p join public.config_mari_carrossel k on k.plano_codigo = p.codigo
                                    where k.ativo and k.plano_codigo = c.plano_escolhido limit 1),
                                  (select p.nome from public.config_planos p join public.config_mari_carrossel k on k.plano_codigo = p.codigo
                                    where k.ativo order by k.ordem limit 1))) end,
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
