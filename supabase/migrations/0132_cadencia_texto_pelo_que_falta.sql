-- NIOGEN | supabase/migrations/0132_cadencia_texto_pelo_que_falta.sql | 12/11/2026 — Claude Code
-- Achado 4 da 1ª auditoria da Mari (Ricardo: "Sim, ataca"): o F2 das 9h pediu "o CEP e o número" ao Cristiano, que já tinha
-- mandado os dois na véspera. Medido: 16 toques em 3 dias pediram CEP/número a quem já tinha dado. Causa: o texto saía da
-- ETAPA, e a etapa fica em "endereco" enquanto falta só o complemento (ele mandou só a referência). Agora o texto sai do que
-- REALMENTE falta, na ordem do fluxo da Mari: CEP → número → complemento/referência → operadora → plano → dados → resumo.
-- Mesma assinatura e mesmos textos de antes onde a etapa estava certa; textos novos só para número e complemento.

CREATE OR REPLACE FUNCTION public.mari_cadencia_texto(c mari_conversas, p_passo text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select case
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
