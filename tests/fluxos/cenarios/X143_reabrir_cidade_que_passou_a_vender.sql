-- id: X143
-- titulo: Caso L-382 (0419, Ricardo 26/11: "Só os 3 leads"): lead recusado por cidade antes da área abrir guardou dentro_area = false e o Reabrir recusava. O recálculo refaz o retrato pela área de hoje (sem reabrir ninguém); o time reabre pela porta. Ligar área libera sozinho; desligar não mexe em conversa existente
-- tipo: atual

-- 1) um lead de Cuiabá com o retrato de quando MT estava desligada, em Saída
select sim.lead_pronto('Duda X143') as a \gset
select sim._servico();
update public.mari_conversas set cep = '78005000', cidade = 'Cuiabá', uf = 'MT', cluster = null, dentro_area = false, elegibilidade = 'fora_area',
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Cuiabá', 'uf', 'MT')
 where id = :'a';
select sim.como('backoffice');
select public.lead_sair(:'a', null, 'cidade_nao_atendida');
select sim.fila_rodar();

-- 2) sem o recálculo, o Reabrir recusa pelo retrato velho
select sim.como('backoffice');
create temp table _x143 (caso text, ok boolean, msg text);
create temp table _x143v as select :'a'::uuid as conv;
do $$
begin
  begin
    perform public.lead_reabrir((select conv from _x143v), null);
    insert into _x143 values ('antes', false, 'reabriu');
  exception when others then insert into _x143 values ('antes', sqlerrm like '%continua fora da área%', sqlerrm);
  end;
end $$;
select sim.confere('retrato velho: o Reabrir recusa "continua fora da área" (o caso do L-382)', (select ok from _x143 where caso = 'antes'), (select msg from _x143 where caso = 'antes'));

-- 3) o recálculo refaz o retrato e não reabre ninguém
select sim.como('servico');
select public._area_recalcular_conversas(null, null);
select sim.confere('recálculo: Cuiabá dentro da área, cluster Regular, elegibilidade fora_area limpa',
  (select dentro_area and cluster = 'regular' and elegibilidade is null from public.mari_conversas where id = :'a'), null);
select sim.confere('recálculo não reabre: o lead continua em Saída', sim.lead_de(:'a') ->> 'destino' = 'saida', sim.lead_de(:'a')::text);

-- 4) o time reabre pela porta
select sim.como('backoffice');
select public.lead_reabrir(:'a', null);
select sim.fila_rodar();
select sim.confere('o time reabre e o lead volta ao andamento', sim.lead_de(:'a') ->> 'destino' = 'em_andamento', sim.lead_de(:'a')::text);

-- 5) ligar área libera sozinho; desligar não mexe em conversa que já existe (a venda nova é barrada pelo trigger)
select sim.como('servico');
select public._area_ativar('MT', null, false, 'teste X143 desliga', 'sim');
select sim.confere('MT desligada: a conversa de Cuiabá não muda (nada por fora da porta)',
  (select dentro_area from public.mari_conversas where id = :'a'), null);
update public.mari_conversas set dentro_area = false, cluster = null where id = :'a';   -- retrato velho de novo
select public._area_ativar('MT', null, true, 'teste X143 liga', 'sim');
select sim.confere('MT ligada: o retrato velho é liberado sozinho', (select dentro_area and cluster = 'regular' from public.mari_conversas where id = :'a'), null);

-- 6) conferência
select sim.confere('conferência: item area_retrato_conversa ok',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_retrato_conversa' and i ->> 'nivel' = 'ok'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_retrato_conversa'));
