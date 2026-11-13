-- NIOGEN · 0159_lead_registrar_consulta · 12/11/2026 (Claude Code / Fable 5.2, etapa 4a do plano do sistema fechado — ficha única)
-- Resumo: o backoffice grava no LEAD SEM VENDA o que o operador leu no portal (viabilidade "viável" ou o resultado do crédito),
--         direto da ficha única. Antes a leitura sumia ao fechar a ficha: só a Mari gravava na conversa (mari_viab_gravar /
--         mari_credito_gravar, service_role). A escada (v_leads) anda sozinha com esses campos.
-- Regras: só admin/backoffice · só conversa sem venda (com venda, o caminho é "Registrar na venda") · "sem viabilidade" não se
--         grava por aqui (viraria Saída automática pela 0147: a pessoa usa Saída › Fachada não atendida, com o motivo) ·
--         nada é mandado ao cliente · toda gravação entra em operador_consultas com origem 'tela' e o usuário.
-- parceiro_id: operador_consultas já tem (default 'dharma'); nenhuma tabela nova.

create or replace function public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true)
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento') then
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' else 'já tem pedido em andamento' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$$;
revoke all on function public.lead_registrar_consulta(uuid, text, text) from public, anon;
grant execute on function public.lead_registrar_consulta(uuid, text, text) to authenticated;

comment on function public.lead_registrar_consulta(uuid, text, text) is
  'Ficha única (0159): admin/backoffice grava no lead sem venda a viabilidade "viável" ou o resultado do crédito lidos pelo operador. Não fala com o cliente.';
