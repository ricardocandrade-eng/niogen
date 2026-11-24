-- NIOGEN | supabase/migrations/0375_credito_origem_regravado_e_complemento_on.sql | 23/11/2026 — Claude Code / Fable 5.2
-- Ricardo, 23/11 (L-259): "Corrige tudo" — dois consertos de dado que a avaliação da venda achou.
-- O que muda:
--   1. QUEM CONSULTOU O CRÉDITO. A 0336 só carimbava mari_conversas.credito_origem quando o RESULTADO mudava. No L-259 a Mari
--      gravou o resultado e, dois segundos depois, a ficha registrou o MESMO resultado: a hora mudou, o rótulo ficou "a Mari".
--      Agora o gatilho roda também quando a hora do crédito (credito_em) é regravada — quem regrava assina.
--      Hora apagada (credito_em = null, usado para liberar nova consulta) não troca o rótulo.
--      Os já gravados com a hora da ficha e o rótulo da Mari (3 conversas) são corrigidos para 'ficha'.
--   2. COMPLEMENTO "on". A extensão lia a caixa de marcar "Sem complemento" do portal (valor "on") como se fosse o complemento.
--      A extensão 0.11.2 deixa de ler; aqui lead_dados_do_portal e venda_dados_do_portal recusam "on"/"off" (para quem ainda usa a
--      versão antiga), e os dois registros já gravados com "on" (1 conversa, 1 venda) voltam a ficar sem complemento — na conversa,
--      a viabilidade gravada é mantida (o endereço consultado não mudou; "on" nunca foi complemento).
-- Regra 20: nenhum estado de lead muda, nenhum aviso ao cliente sai (o gatilho mexe só no rótulo; os avisos do crédito seguem
-- presos à mudança do RESULTADO). As duas funções do portal ficam iguais à produção, com uma condição a mais no complemento.

begin;

-- 1. quem regrava o crédito assina, mesmo com o resultado igual
drop trigger if exists mari_conversas_credito_origem on public.mari_conversas;
create trigger mari_conversas_credito_origem before update of credito_resultado, credito_em on public.mari_conversas
  for each row when (new.credito_resultado is distinct from old.credito_resultado
                     or (new.credito_em is not null and new.credito_em is distinct from old.credito_em))
  execute function public._conversa_credito_origem();

-- os já gravados: rótulo 'mari' com a hora de um registro feito na ficha (mesmo resultado, mesma hora)
update public.mari_conversas c set credito_origem = 'ficha'
 where c.credito_origem = 'mari' and c.credito_resultado is not null and c.credito_em is not null
   and exists (select 1 from public.operador_consultas o
                where o.conversa_id = c.id and o.tipo = 'credito' and o.origem = 'tela' and o.resultado = c.credito_resultado
                  and abs(extract(epoch from (o.criado_em - c.credito_em))) < 2);

-- 2. "on"/"off" não é complemento
CREATE OR REPLACE FUNCTION public.lead_dados_do_portal(p_conversa uuid, p_campos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  a       public.mari_conversas;   -- como estava (para devolver a viabilidade que o gatilho de endereço zera)
  quem    text;
  mud     text[] := '{}';
  fora    text[] := '{}';
  v_txt   text;
  v_dig   text;
  v_dados jsonb;
  v_plano public.config_planos;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Já é venda: nada gravado no lead'); end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Nada lido'); end if;
  a := c;
  v_dados := coalesce(c.dados, '{}'::jsonb);

  -- o pedido aberto no portal é deste lead? CPF diferente do gravado = outra pessoa na tela: nada é gravado
  v_dig := regexp_replace(coalesce(p_campos ->> 'cpf', ''), '\D', '', 'g');
  if v_dig <> '' and coalesce(public._so_digitos(v_dados ->> 'cpf'), '') <> '' and public._so_digitos(v_dados ->> 'cpf') <> v_dig then
    raise exception 'O CPF do pedido aberto no portal não é o deste lead: nada foi gravado.';
  end if;
  if v_dig <> '' and coalesce(public._so_digitos(v_dados ->> 'cpf'), '') = '' then
    if (length(v_dig) = 11 and public._cpf_ok(v_dig)) or length(v_dig) = 14 then
      v_dados := v_dados || jsonb_build_object('cpf', v_dig); mud := array_append(mud, 'CPF');
    end if;
  end if;

  -- só o que está VAZIO na ficha: o portal completa, nunca troca o que alguém gravou
  v_txt := nullif(btrim(p_campos ->> 'nome'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'nome'), '') = '' and v_txt ~ '\S+\s+\S+' then
    v_dados := v_dados || jsonb_build_object('nome', left(v_txt, 120)); mud := array_append(mud, 'nome');
  end if;
  v_txt := nullif(lower(btrim(p_campos ->> 'email')), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'email'), '') = '' and v_txt ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_dados := v_dados || jsonb_build_object('email', v_txt); mud := array_append(mud, 'e-mail');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'numero'), '');
  if v_txt is not null and coalesce(btrim(c.numero), '') = '' then c.numero := left(v_txt, 20); mud := array_append(mud, 'número'); end if;
  v_txt := nullif(btrim(p_campos ->> 'complemento'), '');   -- 0375: "on"/"off" é a caixa "Sem complemento" do portal, não um complemento
  if v_txt is not null and lower(v_txt) not in ('on', 'off') and coalesce(btrim(c.complemento), '') = '' then c.complemento := left(v_txt, 60); mud := array_append(mud, 'complemento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'rua'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'rua_confirmada'), '') = '' and coalesce(btrim(c.endereco_cep ->> 'logradouro'), '') = '' then
    v_dados := v_dados || jsonb_build_object('rua_confirmada', left(v_txt, 120)); mud := array_append(mud, 'rua');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'referencia'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'referencia'), '') = '' then
    v_dados := v_dados || jsonb_build_object('referencia', left(v_txt, 120)); mud := array_append(mud, 'referência');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'plano'), '');
  if v_txt is not null and coalesce(btrim(c.plano_escolhido), '') = '' then
    select * into v_plano from public.config_planos where codigo = v_txt and ativo;
    if not found then fora := array_append(fora, 'plano fora da tabela vigente');
    elsif c.cluster is not null and v_plano.cluster is distinct from c.cluster then fora := array_append(fora, 'plano de outra faixa de preço');
    else c.plano_escolhido := v_txt; mud := array_append(mud, 'plano'); end if;
  end if;
  v_txt := nullif(btrim(p_campos ->> 'forma'), '');
  if v_txt is not null and coalesce(btrim(c.forma_pagamento), '') = '' and v_txt in ('boleto', 'cartao', 'dacc') then
    c.forma_pagamento := v_txt; mud := array_append(mud, 'pagamento');
  end if;

  if array_length(mud, 1) is null then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'fora', to_jsonb(fora), 'resumo', 'Nada novo para gravar');
  end if;

  update public.mari_conversas
     set dados = v_dados, numero = c.numero, complemento = c.complemento,
         plano_escolhido = c.plano_escolhido, forma_pagamento = c.forma_pagamento
   where id = p_conversa;
  -- número/complemento novos disparam o gatilho que zera a viabilidade (_mari_viab_endereco_mudou). Aqui o dado veio do PEDIDO
  -- no portal, que acabou de dar viável exatamente para este endereço: a viabilidade gravada continua valendo.
  if a.nio_viab_em is not null and (c.numero is distinct from a.numero or c.complemento is distinct from a.complemento) then
    update public.mari_conversas
       set nio_viab_em = a.nio_viab_em, nio_viab_resultado = a.nio_viab_resultado, nio_viab_velocidade = a.nio_viab_velocidade,
           cobertura_decisao = a.cobertura_decisao, cobertura_detalhe = a.cobertura_detalhe, cobertura_em = a.cobertura_em,
           rua_conferir_em = a.rua_conferir_em, unidade_conferir_em = a.unidade_conferir_em
     where id = p_conversa;
  end if;

  select nome into quem from public.usuarios where id = auth.uid();
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema', '[dados lidos do pedido no portal (extensão, ' || coalesce(quem, 'time') || '): ' || array_to_string(mud, ', ') || ']', false);

  return jsonb_build_object('ok', true, 'mudou', to_jsonb(mud), 'fora', to_jsonb(fora),
                            'resumo', '✓ Gravado na ficha (do portal): ' || array_to_string(mud, ', '));
end $function$;

CREATE OR REPLACE FUNCTION public.venda_dados_do_portal(p_venda uuid, p_campos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v       public.vendas;
  c       public.mari_conversas;
  mud     text[] := '{}';
  fora    text[] := '{}';
  v_txt   text;
  v_dig   text;
  v_plano public.config_planos;
  v_prov  boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Nada lido'); end if;
  -- depois da OS o que vale é o que foi para a Nio: nada é completado sozinho
  if v.status <> '0_qualificado' or coalesce(btrim(v.nio_os), '') <> '' then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Venda já com OS: nada gravado');
  end if;
  v_dig := regexp_replace(coalesce(p_campos ->> 'cpf', ''), '\D', '', 'g');
  if v_dig <> '' and coalesce(public._so_digitos(v.cliente_cpf_cnpj), '') <> '' and public._so_digitos(v.cliente_cpf_cnpj) <> v_dig then
    raise exception 'O CPF do pedido aberto no portal não é o desta venda: nada foi gravado.';
  end if;
  select * into c from public.mari_conversas where venda_id = v.id order by created_at desc limit 1;

  -- nome: só troca o PROVISÓRIO (venda nascida sem o nome do titular: a conversa ainda não tem dados.nome)
  v_prov := c.id is not null and coalesce(btrim(c.dados ->> 'nome'), '') = '';
  v_txt := nullif(btrim(p_campos ->> 'nome'), '');
  if v_txt is not null and v_txt ~ '\S+\s+\S+' and v_prov then
    if lower(btrim(v.cliente_nome)) is distinct from lower(v_txt) then v.cliente_nome := left(v_txt, 120); mud := array_append(mud, 'nome'); end if;
    update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('nome', left(v_txt, 120)) where id = c.id;
  end if;
  v_txt := nullif(lower(btrim(p_campos ->> 'email')), '');
  if v_txt is not null and coalesce(btrim(v.cliente_email), '') = '' and v_txt ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v.cliente_email := v_txt; mud := array_append(mud, 'e-mail'); end if;
  v_txt := nullif(btrim(p_campos ->> 'numero'), '');
  if v_txt is not null and coalesce(btrim(v.numero), '') = '' then v.numero := left(v_txt, 20); mud := array_append(mud, 'número'); end if;
  v_txt := nullif(btrim(p_campos ->> 'complemento'), '');   -- 0375: "on"/"off" é a caixa "Sem complemento" do portal, não um complemento
  if v_txt is not null and lower(v_txt) not in ('on', 'off') and coalesce(btrim(v.complemento), '') = '' then v.complemento := left(v_txt, 60); mud := array_append(mud, 'complemento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'rua'), '');
  if v_txt is not null and coalesce(btrim(v.logradouro), '') = '' then v.logradouro := left(v_txt, 120); mud := array_append(mud, 'rua'); end if;
  v_txt := nullif(btrim(p_campos ->> 'referencia'), '');
  if v_txt is not null and coalesce(btrim(v.ponto_referencia), '') = '' then v.ponto_referencia := left(v_txt, 120); mud := array_append(mud, 'referência'); end if;
  v_txt := nullif(btrim(p_campos ->> 'forma'), '');
  if v_txt is not null and v.forma_pagamento is null and v_txt in ('boleto', 'cartao', 'dacc') then v.forma_pagamento := v_txt; mud := array_append(mud, 'pagamento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'plano'), '');
  if v_txt is not null and v.plano_id is null then
    select * into v_plano from public.config_planos where codigo = v_txt and ativo;
    if not found then fora := array_append(fora, 'plano fora da tabela vigente');
    else v.plano_id := v_plano.id; mud := array_append(mud, 'plano'); end if;
  end if;

  if array_length(mud, 1) is null then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'fora', to_jsonb(fora), 'resumo', 'Nada novo para gravar');
  end if;
  update public.vendas
     set cliente_nome = v.cliente_nome, cliente_email = v.cliente_email, numero = v.numero, complemento = v.complemento,
         logradouro = v.logradouro, ponto_referencia = v.ponto_referencia, forma_pagamento = v.forma_pagamento, plano_id = v.plano_id
   where id = v.id;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'dados_do_portal', jsonb_build_object('campos', to_jsonb(mud), 'origem', 'extensao'), auth.uid());
  return jsonb_build_object('ok', true, 'mudou', to_jsonb(mud), 'fora', to_jsonb(fora),
                            'resumo', '✓ Gravado na venda (do portal): ' || array_to_string(mud, ', '));
end $function$;

-- os já gravados com "on"/"off": ficam sem complemento. Na conversa o gatilho do endereço zeraria a viabilidade; ela é devolvida,
-- porque o endereço consultado não mudou.
do $$
declare a public.mari_conversas;
begin
  for a in select * from public.mari_conversas where lower(btrim(complemento)) in ('on', 'off') loop
    update public.mari_conversas set complemento = null where id = a.id;
    if a.nio_viab_em is not null then
      update public.mari_conversas
         set nio_viab_em = a.nio_viab_em, nio_viab_resultado = a.nio_viab_resultado, nio_viab_velocidade = a.nio_viab_velocidade,
             cobertura_decisao = a.cobertura_decisao, cobertura_detalhe = a.cobertura_detalhe, cobertura_em = a.cobertura_em,
             rua_conferir_em = a.rua_conferir_em, unidade_conferir_em = a.unidade_conferir_em
       where id = a.id;
    end if;
  end loop;
end $$;
update public.vendas set complemento = null where lower(btrim(complemento)) in ('on', 'off');

commit;
