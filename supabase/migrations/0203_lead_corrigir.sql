-- NIOGEN | supabase/migrations/0203_lead_corrigir.sql | 14/11/2026 — Claude Code / Opus 5.5
-- Ficha nova (protótipo aprovado pelo Ricardo em 14/11 ~22h40: claude.ai/artifact/JH89gqH3rPLgGCgnscJCiT, tela 3 "Corrigir um dado").
-- Antes: num lead SEM venda nenhum dado do cliente era editável por humano (só a Mari gravava). Agora o time corrige na ficha:
--   lead_corrigir(conversa, campos) — admin/backoffice; lead sem venda; campos: nome, cpf, email, cep (+ endereco_cep do ViaCEP),
--   numero, complemento, rua (rua confirmada), referencia, plano (codigo da tabela), forma (boleto|cartao|dacc), instalacao.
-- Regras:
--   · CEP novo: cidade/UF/bairro vêm do ViaCEP mandado pela tela; área e cluster recalculados por cluster_da_area() (o mesmo da Mari).
--   · Endereço mudou (CEP, número, complemento ou rua): o gatilho _mari_viab_endereco_mudou zera a viabilidade (0202) e a
--     mari_viab_pendentes volta a consultar o portal em até 2 min — com a rua corrigida como rua esperada. O teto de 3 consultas
--     por conversa não segura a correção do time (viab_consultas volta a 2 no máximo).
--   · Plano: só da tabela vigente e do mesmo cluster da conversa. Forma: boleto, cartão ou débito automático.
--   · Toda correção vira uma linha de sistema na conversa ("[dados corrigidos no NIOGEN por X: …]") — a Mari e o histórico veem.
-- Regra 20: (3) estado muda por função do banco, com autor; (4) fonte única = a conversa (a venda nasce dela no handoff).

create or replace function public.lead_corrigir(p_conversa uuid, p_campos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c        public.mari_conversas;
  quem     text;
  k        text;
  mud      text[] := '{}';
  v_txt    text;
  v_dig    text;
  v_cep    text;
  v_plano  public.config_planos;
  v_vc     jsonb;
  v_end    boolean := false;
  v_dados  jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: corrija na venda.'; end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then raise exception 'Nada para corrigir.'; end if;
  for k in select jsonb_object_keys(p_campos) loop
    if k not in ('nome', 'cpf', 'email', 'cep', 'endereco_cep', 'numero', 'complemento', 'rua', 'referencia', 'plano', 'forma', 'instalacao') then
      raise exception 'Campo desconhecido: %', k;
    end if;
  end loop;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');
  v_dados := coalesce(c.dados, '{}'::jsonb);

  -- contato
  if p_campos ? 'nome' then
    v_txt := nullif(btrim(p_campos ->> 'nome'), '');
    if v_txt is null or length(v_txt) < 3 then raise exception 'Nome muito curto.'; end if;
    v_dados := v_dados || jsonb_build_object('nome', left(v_txt, 120)); mud := array_append(mud, 'nome');
  end if;
  if p_campos ? 'cpf' then
    v_dig := regexp_replace(coalesce(p_campos ->> 'cpf', ''), '\D', '', 'g');
    if v_dig = '' then v_dados := v_dados - 'cpf';
    elsif length(v_dig) = 11 and public._cpf_ok(v_dig) then v_dados := v_dados || jsonb_build_object('cpf', v_dig);
    elsif length(v_dig) = 14 then v_dados := v_dados || jsonb_build_object('cpf', v_dig);
    else raise exception 'CPF/CNPJ inválido (confira os dígitos).'; end if;
    mud := array_append(mud, 'CPF');
  end if;
  if p_campos ? 'email' then
    v_txt := nullif(lower(btrim(p_campos ->> 'email')), '');
    if v_txt is not null and v_txt !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
    v_dados := case when v_txt is null then v_dados - 'email' else v_dados || jsonb_build_object('email', v_txt) end; mud := array_append(mud, 'e-mail');
  end if;

  -- endereço
  if p_campos ? 'cep' then
    v_cep := regexp_replace(coalesce(p_campos ->> 'cep', ''), '\D', '', 'g');
    if length(v_cep) <> 8 then raise exception 'CEP com 8 dígitos.'; end if;
    if v_cep is distinct from regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') then
      v_vc := p_campos -> 'endereco_cep';
      if v_vc is null or jsonb_typeof(v_vc) <> 'object' or coalesce((v_vc ->> 'erro')::boolean, false) then
        raise exception 'CEP não encontrado no ViaCEP — confira o número.';
      end if;
      c.cep := v_cep; c.endereco_cep := v_vc; c.cidade := v_vc ->> 'localidade'; c.uf := v_vc ->> 'uf';
      c.cluster := public.cluster_da_area(c.cidade, c.uf, v_vc ->> 'bairro');
      c.dentro_area := c.cluster is not null;
      c.dfv_resultado := null; c.dfv_detalhe := null;
      v_end := true; mud := array_append(mud, 'CEP');
    end if;
  end if;
  if p_campos ? 'numero' then
    v_txt := nullif(btrim(p_campos ->> 'numero'), '');
    if v_txt is null then raise exception 'Número do endereço vazio (use SN se não tiver).'; end if;
    if v_txt is distinct from c.numero then c.numero := left(v_txt, 20); v_end := true; mud := array_append(mud, 'número'); end if;
  end if;
  if p_campos ? 'complemento' then
    v_txt := nullif(btrim(p_campos ->> 'complemento'), '');
    if v_txt is distinct from c.complemento then c.complemento := left(v_txt, 60); v_end := true; mud := array_append(mud, 'complemento'); end if;
  end if;
  if p_campos ? 'rua' then
    v_txt := nullif(btrim(p_campos ->> 'rua'), '');
    if v_txt is distinct from nullif(v_dados ->> 'rua_confirmada', '') then
      v_dados := case when v_txt is null then v_dados - 'rua_confirmada' else v_dados || jsonb_build_object('rua_confirmada', left(v_txt, 120)) end;
      v_end := true; mud := array_append(mud, 'rua');
    end if;
  end if;
  if p_campos ? 'referencia' then
    v_txt := nullif(btrim(p_campos ->> 'referencia'), '');
    v_dados := case when v_txt is null then v_dados - 'referencia' else v_dados || jsonb_build_object('referencia', left(v_txt, 120)) end; mud := array_append(mud, 'referência');
  end if;

  -- o que o cliente quer
  if p_campos ? 'plano' then
    v_txt := nullif(btrim(p_campos ->> 'plano'), '');
    if v_txt is not null then
      select * into v_plano from public.config_planos where codigo = v_txt and ativo;
      if not found then raise exception 'Plano fora da tabela vigente.'; end if;
      if c.cluster is not null and v_plano.cluster is distinct from c.cluster then raise exception 'Plano de outra faixa de preço (a cidade é %).', c.cluster; end if;
    end if;
    c.plano_escolhido := v_txt; mud := array_append(mud, 'plano');
  end if;
  if p_campos ? 'forma' then
    v_txt := nullif(btrim(p_campos ->> 'forma'), '');
    if v_txt is not null and v_txt not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento: boleto, cartao ou dacc.'; end if;
    c.forma_pagamento := v_txt; mud := array_append(mud, 'pagamento');
  end if;
  if p_campos ? 'instalacao' then
    c.instalacao_preferencia := left(nullif(btrim(p_campos ->> 'instalacao'), ''), 80); mud := array_append(mud, 'instalação');
  end if;

  if array_length(mud, 1) is null then
    return jsonb_build_object('ok', true, 'resumo', 'Nada mudou');
  end if;

  update public.mari_conversas
     set dados = v_dados, cep = c.cep, endereco_cep = c.endereco_cep, cidade = c.cidade, uf = c.uf, cluster = c.cluster,
         dentro_area = c.dentro_area, dfv_resultado = c.dfv_resultado, dfv_detalhe = c.dfv_detalhe,
         numero = c.numero, complemento = c.complemento,
         plano_escolhido = c.plano_escolhido, forma_pagamento = c.forma_pagamento, instalacao_preferencia = c.instalacao_preferencia,
         viab_consultas = case when v_end then least(viab_consultas, 2) else viab_consultas end
   where id = p_conversa;
  -- a rua sozinha não dispara o gatilho de endereço (ele olha cep/número/complemento): zera a viabilidade aqui
  if v_end then
    update public.mari_conversas
       set nio_viab_em = null, nio_viab_resultado = null, nio_viab_velocidade = null,
           cobertura_decisao = null, cobertura_detalhe = null, cobertura_em = null, rua_conferir_em = null
     where id = p_conversa;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema', '[dados corrigidos no NIOGEN por ' || quem || ': ' || array_to_string(mud, ', ') || ']', false);

  return jsonb_build_object('ok', true, 'mudou', to_jsonb(mud), 'endereco', v_end,
    'resumo', '✓ Corrigido: ' || array_to_string(mud, ', ')
              || case when v_end then ' · a viabilidade é consultada de novo em até 2 min' else '' end);
end $$;
revoke all on function public.lead_corrigir(uuid, jsonb) from public, anon;
grant execute on function public.lead_corrigir(uuid, jsonb) to authenticated;
comment on function public.lead_corrigir(uuid, jsonb) is
  '0203: admin/backoffice corrige os dados do lead sem venda (contato, endereço, plano, forma, instalação). Endereço mudou → viabilidade refeita pela fila da Mari. Linha de sistema na conversa.';
