-- id: B2
-- titulo: CEP sem cobertura: Saída "Fachada não atendida" com retorno em 90 dias
-- tipo: atual
select sim.lead_novo('Dora B2') as c \gset
select sim.mari_handoff(:'c', 'sem_cobertura', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('Saída Sem cobertura', sim.lead_de(:'c') ->> 'destino' = 'saida' and sim.lead_de(:'c') ->> 'saida' = 'fachada_nao_atendida', sim.lead_de(:'c')::text);
select volta_em::text as volta from public.v_leads where conversa_id = :'c' \gset
select sim.confere('retorno marcado para daqui a ~90 dias', :'volta' <> '' and :'volta'::date between current_date + 80 and current_date + 100, 'volta em: ' || :'volta');
select sim.passa(:'c', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência não manda nada enquanto isso', :n = 0, 'envios: ' || :n);
