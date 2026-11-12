-- NIOGEN | supabase/migrations/0142_cutucadas_texto_e_contexto.sql | 12/11/2026 — Claude Code
-- Cinco cutucadas (0141): textos de reserva do F3–F5 e o contexto que a Mari recebe para escrever cada cutucada.

CREATE OR REPLACE FUNCTION public.mari_cadencia_texto(c mari_conversas, p_passo text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select case
    -- 0141/0142: F3/F4 reaproveitam o F1/F2 da etapa; F5 é a última chamada da janela (reserva — o texto normal vem da Mari).
    when p_passo = 'F5' then 'Vou deixar o seu atendimento separado até amanhã 😊 Quer que eu siga com o seu pedido?'
    when p_passo in ('F3', 'F4') then public.mari_cadencia_texto(c, case p_passo when 'F3' then 'F1' else 'F2' end)
    when p_passo = 'L15' then coalesce((select t.texto from public.config_mari_textos t where t.chave = 'abertura_lembrete'),
                                       'Se ficar mais fácil, me manda só o nome da rua e o bairro 😉')
    -- sem CEP: abertura B2 pede só o CEP (ou rua e bairro); sem B2, CEP e número
    when c.cep is null and coalesce(c.dados ->> 'abertura', '') <> '' then case p_passo
      when 'F1' then 'Conseguiu achar o CEP? Com ele (ou a rua e o bairro) eu já te mostro os planos da sua região 😊'
      else 'Passando aqui rapidinho: se me mandar o CEP (ou a rua e o bairro), te mostro os planos da sua região 😊' end
    when c.cep is null then case p_passo
      when 'F1' then 'Conseguiu ver o CEP e o número da casa? Com eles eu já te mostro as opções 😊'
      else 'Passando aqui rapidinho: se me mandar o CEP e o número, te mostro os planos da sua região 😊' end
    when nullif(btrim(coalesce(c.numero, '')), '') is null then case p_passo
      when 'F1' then 'Só falta o número da casa pra eu te mostrar as opções daí 😊'
      else 'Passando aqui rapidinho: me manda o número da casa que eu já te mostro os planos da sua região 😊' end
    when c.elegibilidade is null and c.complemento is null and coalesce(c.dados ->> 'referencia', '') = ''
         and coalesce(c.dados ->> 'complemento_ok', '') = '' then case p_passo
      when 'F1' then 'Tem complemento (casa A ou B, apto, bloco) ou um ponto de referência perto da sua casa? Com isso eu já sigo 😊'
      else 'Passando aqui rapidinho: me conta se tem complemento ou um ponto de referência perto da sua casa, que eu sigo com as opções 😊' end
    when c.elegibilidade is null then case p_passo
      when 'F1' then 'Só falta essa: hoje você usa internet de qual operadora? Com isso eu já te mostro as opções 😊'
      else 'Passando aqui rapidinho: me conta qual operadora você usa hoje que eu sigo com as opções 😊' end
    when c.plano_escolhido is null then case p_passo
      when 'F1' then 'Ficou alguma dúvida sobre os planos? Se quiser, te ajudo a escolher 😊'
      else 'Separei as opções da sua região. Qual delas te chamou mais atenção? 😊' end
    when coalesce(c.etapa, '') <> 'resumo' then case p_passo   -- plano escolhido: falta dado (mesmo com a etapa atrasada)
      when 'F1' then 'Estamos quase lá! Falta só ' || public.mari_cadencia_campo_falta(c) || ' pra eu adiantar seu pedido 😊'
      else 'Seu pedido está quase pronto — me passa ' || public.mari_cadencia_campo_falta(c) || ' quando puder? 😊' end
    else case p_passo   -- resumo (e qualquer etapa nova)
      when 'F1' then 'Conseguiu conferir os dados? Se estiver tudo certo, é só me confirmar 😊'
      else 'Seus dados estão prontos pra seguir — me confirma que está tudo certo? 😊' end
  end
$function$;

-- Contexto para a Mari escrever a cutucada (n8n mari_cadencia, nó 4b): quem é, onde parou, o que falta e as últimas falas.
create or replace function public.mari_cutucada_contexto(p_conversa uuid, p_passo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.mari_conversas; v jsonb;
begin
  select * into c from public.mari_conversas where id = p_conversa;
  if c.id is null then return null; end if;
  select jsonb_build_object(
    'passo', p_passo,
    'numero_da_cutucada', case p_passo when 'F1' then 1 when 'F2' then 2 when 'F3' then 3 when 'F4' then 4 when 'F5' then 5 else 1 end,
    'nome', case when coalesce(c.nome_confiavel, false) then split_part(coalesce(c.dados->>'nome', c.nome_contato, ''), ' ', 1) end,
    'cidade', c.cidade, 'etapa', c.etapa,
    'tem_cep', c.cep is not null, 'tem_numero', c.numero is not null,
    'plano_escolhido', (select p.nome from public.config_planos p where p.codigo = c.plano_escolhido),
    'falta', case when c.plano_escolhido is not null then public.mari_cadencia_campo_falta(c) end,
    'cobertura', c.cobertura_decisao,
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
end $$;
revoke all on function public.mari_cutucada_contexto(uuid, text) from public, anon, authenticated;
grant execute on function public.mari_cutucada_contexto(uuid, text) to service_role;
