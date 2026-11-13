-- NIOGEN | 0174_degrau_os_aberta.sql | 13/11/2026 — Claude Code (Ricardo, 13/11: "ficou estranho as duas etapas com os nomes
-- Instalação > Instalada" → combinado "OS aberta → Instalada").
-- Só o NOME do 5º degrau da escada muda, em config_lead: o código continua 'instalacao' (v_leads, Live, Agente de Tráfego,
-- etiquetas e filtros usam o código e não mudam). Leads, Funil, Painel e a ficha leem o nome daqui.
update public.config_lead
   set nome = 'OS aberta',
       ajuda = 'A OS está aberta na Nio: é venda. Falta a Nio instalar. Na ficha, clique neste degrau para consultar a OS na Nio agora.'
 where tipo = 'etapa' and codigo = 'instalacao' and nome = 'Instalação';
