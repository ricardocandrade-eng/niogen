-- NIOGEN | supabase/migrations/0275_mapa_botoes.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Reta final, decisão 3 do Ricardo (18/11): o MAPA SITUAÇÃO × BOTÃO (artifact GqWi6YHhidQXw4Ta9gG4JK). As 15 situações × os 24 botões
-- da ficha, extensão e Live; Ricardo: "Pode seguir com o mapa e suas recomendações" + "Cliente nosso temos que dar pós venda"
-- (Instalada não silencia o suporte) + "Pode aplicar quando terminar".
-- O que muda: config_transicao fica estreita — cada botão só vale onde é o passo. São linhas exatas (evento × situação), que vencem
-- a regra de família/grupo (porta_prever lê o evento exato e a situação exata primeiro):
--   · recusa com a frase que a tela mostra em "Não vale agora" (viabilidade/crédito depois do crédito aprovado, agenda antes da OS,
--     Virar venda com venda, passos da venda em Saída "pode voltar" → Reabrir primeiro, Devolver com a Mari, Reativar fora do Cliente Nio…);
--     os passos da venda nas situações 1–3 ficam como estão (lead "com o time" pode ter venda — B5) e Agendar vale em "aguardando a Nio" sem data;
--   · "só o admin" (exige = admin): Nio dispensou a biometria, corrigir pedido/OS depois de gravados, biometria à mão em venda antiga,
--     Trocar o titular depois da biometria, Mover, Responder Cliente Nio.
-- E duas funções que não perguntavam à porta passam a perguntar (só o __nucleo muda; a casca da 0263 fica):
--   · backoffice_responder__nucleo: confere 'time_respondeu' (nota interna não);
--   · backoffice_conversa_espera__nucleo: confere 'aguardar'.
-- Regra 20: (1) nenhuma situação nova; (2) nada fica parado — só some o botão que não é do passo; (3) a mudança continua pela função
-- do banco, agora recusada antes; (4) fonte única: a tabela; (5) conferência: cenário X18 no portão (cada linha nova recusa/exige o que
-- diz, a tela mostra a mesma frase) e R13 (o botão da Live vale na porta).
begin;

insert into public.config_transicao (evento, de, para, aceito, frase, exige, nota) values
  ('time_respondeu', 'nao_contatar', null, false, 'O cliente pediu para não ser contatado.', null, '0275 mapa (antes: M)'),
  ('time_respondeu', 'cliente_nio', array['=']::text[], true, 'Cliente Nio: só o admin responde (o time não atende cliente Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:devolver_mari', 'mari_atendendo', null, false, 'A conversa já está com a Mari.', null, '0275 mapa (antes: M)'),
  ('momento:devolver_mari', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('aguardar', 'saida_pode_voltar', null, false, 'O lead está em Saída: a data de volta já é a da Saída.', null, '0275 mapa (antes: ?)'),
  ('virar_venda', 'qualificado_credito', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'qualificado_biometria', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'qualificado_os', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'instalacao_agendar', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'instalacao_aguardando', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'instalacao_pendencia', null, false, 'Este lead já é venda.', null, '0275 mapa (antes: M)'),
  ('virar_venda', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:viabilidade:*', 'qualificado_biometria', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'qualificado_biometria', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'qualificado_os', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'qualificado_os', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'instalacao_agendar', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'instalacao_agendar', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'instalacao_aguardando', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'instalacao_aguardando', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'instalacao_pendencia', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'instalacao_pendencia', null, false, 'A viabilidade já foi registrada nesta venda.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:*', 'saida_definitiva', null, false, 'Saída definitiva: o lead não volta à venda (só o admin reabre).', null, '0275 mapa (antes: M)'),
  ('momento:viabilidade:viavel', 'saida_definitiva', null, false, 'Saída definitiva: o lead não volta à venda (só o admin reabre).', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'qualificado_biometria', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:aprovado', 'qualificado_biometria', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:negado', 'qualificado_biometria', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:pendente', 'qualificado_biometria', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:so_cartao', 'qualificado_biometria', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'qualificado_os', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:aprovado', 'qualificado_os', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:negado', 'qualificado_os', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:pendente', 'qualificado_os', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:so_cartao', 'qualificado_os', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'instalacao_agendar', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:aprovado', 'instalacao_agendar', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:negado', 'instalacao_agendar', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:pendente', 'instalacao_agendar', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:so_cartao', 'instalacao_agendar', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'instalacao_aguardando', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:aprovado', 'instalacao_aguardando', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:negado', 'instalacao_aguardando', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:pendente', 'instalacao_aguardando', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:so_cartao', 'instalacao_aguardando', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'instalacao_pendencia', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:aprovado', 'instalacao_pendencia', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:negado', 'instalacao_pendencia', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:pendente', 'instalacao_pendencia', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:so_cartao', 'instalacao_pendencia', null, false, 'O crédito já foi aprovado. Para outro CPF, use Trocar o titular.', null, '0275 mapa (antes: M)'),
  ('momento:credito:*', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:credito:aprovado', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:credito:negado', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:credito:pendente', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:credito:so_cartao', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:pedido', 'qualificado_biometria', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin corrige o pedido depois de feito.', 'admin', '0275 mapa (antes: M)'),
  ('momento:pedido', 'qualificado_os', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin corrige o pedido depois de feito.', 'admin', '0275 mapa (antes: M)'),
  ('momento:pedido', 'instalacao_agendar', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin corrige o pedido depois de feito.', 'admin', '0275 mapa (antes: M)'),
  ('momento:pedido', 'instalacao_aguardando', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin corrige o pedido depois de feito.', 'admin', '0275 mapa (antes: M)'),
  ('momento:pedido', 'instalacao_pendencia', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin corrige o pedido depois de feito.', 'admin', '0275 mapa (antes: M)'),
  ('momento:pedido', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:biometria:*', 'qualificado_os', null, false, 'A biometria já está validada.', null, '0275 mapa (antes: M)'),
  ('momento:biometria:validada', 'qualificado_os', null, false, 'A biometria já está validada.', null, '0275 mapa (antes: M)'),
  ('momento:biometria:risco', 'qualificado_os', null, false, 'A biometria já está validada.', null, '0275 mapa (antes: M)'),
  ('momento:biometria:negado', 'qualificado_os', null, false, 'A biometria já está validada.', null, '0275 mapa (antes: M)'),
  ('momento:biometria:*', 'instalacao_agendar', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:validada', 'instalacao_agendar', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:risco', 'instalacao_agendar', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:negado', 'instalacao_agendar', array['saida_definitiva', '=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:*', 'instalacao_aguardando', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:validada', 'instalacao_aguardando', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:risco', 'instalacao_aguardando', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:negado', 'instalacao_aguardando', array['saida_definitiva', '=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:*', 'instalacao_pendencia', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:validada', 'instalacao_pendencia', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:risco', 'instalacao_pendencia', array['=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:negado', 'instalacao_pendencia', array['saida_definitiva', '=']::text[], true, 'Só o admin marca a biometria à mão em venda antiga (biometria depois da OS).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:*', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:biometria:validada', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:biometria:risco', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:biometria:negado', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:biometria:dispensada', 'em_espera', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'qualificado_credito', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'qualificado_biometria', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'qualificado_os', null, false, 'A biometria já está validada.', null, '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'instalacao_agendar', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'instalacao_aguardando', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'instalacao_pendencia', array['qualificado_os', 'instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin dispensa a biometria (pula a checagem da Nio).', 'admin', '0275 mapa (antes: M)'),
  ('momento:biometria:dispensada', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:os', 'instalacao_agendar', array['instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin corrige a OS depois de gravada.', 'admin', '0275 mapa (antes: M)'),
  ('momento:os', 'instalacao_aguardando', array['instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin corrige a OS depois de gravada.', 'admin', '0275 mapa (antes: M)'),
  ('momento:os_agendar', 'instalacao_aguardando', array['instalacao_aguardando']::text[], true, 'Só o admin corrige a OS depois de gravada.', 'admin', '0275 mapa (antes: M)'),
  ('momento:os', 'instalacao_pendencia', array['instalacao_agendar', 'instalacao_aguardando']::text[], true, 'Só o admin corrige a OS depois de gravada.', 'admin', '0275 mapa (antes: M)'),
  ('momento:os_agendar', 'instalacao_pendencia', array['instalacao_aguardando']::text[], true, 'Só o admin corrige a OS depois de gravada.', 'admin', '0275 mapa (antes: M)'),
  ('momento:os', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:os_agendar', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:agendar', 'qualificado_credito', null, false, 'A agenda vem junto com a OS, depois da biometria.', null, '0275 mapa (antes: M)'),
  ('momento:agendar', 'qualificado_biometria', null, false, 'A agenda vem junto com a OS, depois da biometria.', null, '0275 mapa (antes: M)'),
  ('momento:agendar', 'qualificado_os', null, false, 'Neste passo a agenda vai junto: use Gravar OS e agenda.', null, '0275 mapa (antes: M)'),
  ('momento:agendar', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('momento:reagendar', 'qualificado_credito', null, false, 'Ainda não há data marcada para trocar.', null, '0275 mapa (antes: M)'),
  ('momento:reagendar', 'qualificado_biometria', null, false, 'Ainda não há data marcada para trocar.', null, '0275 mapa (antes: M)'),
  ('momento:reagendar', 'qualificado_os', null, false, 'Ainda não há data marcada para trocar.', null, '0275 mapa (antes: M)'),
  ('momento:reagendar', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('trocar_titular', 'qualificado_os', array['=', 'qualificado_credito', 'qualificado_biometria']::text[], true, 'Só o admin troca o titular depois da biometria validada.', 'admin', '0275 mapa (antes: M)'),
  ('trocar_titular', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('antifraude:*', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:credito_negado', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'qualificado_credito', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'qualificado_biometria', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'qualificado_os', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'instalacao_agendar', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'instalacao_aguardando', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:fora_area', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:perdida', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:recusou', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_cobertura', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:sem_resposta', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:teste_duplicada', 'instalacao_pendencia', null, false, 'Com venda, a Saída é a da venda (Saída…).', null, '0275 mapa (antes: M)'),
  ('silenciar:credito_negado', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:fora_area', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:perdida', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:recusou', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:sem_cobertura', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:sem_resposta', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:teste_duplicada', 'saida_pode_voltar', null, false, 'O lead está em Saída. Use Reabrir primeiro.', null, '0275 mapa (antes: ?)'),
  ('silenciar:suporte_nio', 'qualificado_credito', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'qualificado_credito', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'qualificado_credito', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:suporte_nio', 'qualificado_biometria', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'qualificado_biometria', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'qualificado_biometria', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:suporte_nio', 'qualificado_os', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'qualificado_os', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'qualificado_os', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:suporte_nio', 'instalacao_agendar', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'instalacao_agendar', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'instalacao_agendar', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:suporte_nio', 'instalacao_aguardando', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'instalacao_aguardando', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'instalacao_aguardando', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:suporte_nio', 'instalacao_pendencia', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente', 'instalacao_pendencia', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:ja_cliente_nio', 'instalacao_pendencia', null, false, 'Com venda em andamento, use a Saída com o motivo "Já é cliente Nio".', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'mari_atendendo', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'time_agora', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'time_esperando', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'em_espera', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'qualificado_credito', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'qualificado_biometria', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'qualificado_os', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'instalacao_agendar', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'instalacao_aguardando', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'instalacao_pendencia', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'instalada', null, false, 'Só conversa silenciada (cliente Nio) se reativa.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'saida_pode_voltar', null, false, 'Para quem saiu, use Reabrir.', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'saida_definitiva', null, false, 'Para quem saiu, use Reabrir (só o admin).', null, '0275 mapa (antes: M)'),
  ('silenciar:reativar', 'nao_contatar', null, false, 'Não contatar volta por Reabrir, e só se o cliente escreveu depois.', null, '0275 mapa (antes: M)'),
  ('momento:parar', 'nao_contatar', null, false, 'O cliente já está em Não contatar.', null, '0275 mapa (antes: M)'),
  ('mover_admin:*', 'mari_atendendo', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'time_agora', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'time_esperando', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'em_espera', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'qualificado_credito', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'qualificado_biometria', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'qualificado_os', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'instalacao_agendar', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'instalacao_aguardando', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'instalacao_pendencia', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'instalada', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'saida_pode_voltar', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'saida_definitiva', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'nao_contatar', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)'),
  ('mover_admin:*', 'cliente_nio', array['*']::text[], true, 'Só o admin move a venda à mão.', 'admin', '0275 mapa (antes: M)')
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, exige = excluded.exige, nota = excluded.nota;

-- backoffice_responder: corpo da produção (md5 6fb6e342…) + a conferência da porta depois do ramo da nota
CREATE OR REPLACE FUNCTION public.backoffice_responder__nucleo(p_conversa uuid, p_texto text, p_nota boolean DEFAULT false, p_template text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  txt      text := btrim(coalesce(p_texto, ''));
  aid      bigint;
  assumiu  boolean := false;
  ult_lead timestamptz;
  ult_out  timestamptz;
  resposta boolean;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_prox   timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice responde pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Nota privada: só o time vê; não é contato com o cliente.
  if coalesce(p_nota, false) then
    if txt = '' then raise exception 'Escreva a nota.'; end if;
    aid := public._bo_enfileirar(g, 1, 'nota', c.venda_id, c, 'nota', jsonb_build_object('content', txt, 'como', 'humano'));
    return jsonb_build_object('ok', true, 'acao_id', aid, 'nota', true, 'resumo', '✓ nota privada salva no Chatwoot (só o time vê)');
  end if;
  -- 0275 (mapa situação × botão): a porta confere antes de falar com o cliente (Não contatar recusa; Cliente Nio só o admin)
  perform public._porta_conferir('time_respondeu', c.id, null::uuid);

  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  -- 0095 (Ricardo, 09/11): atendimento pelo NIOGEN SEM limite de horário e SEM teto de mensagens. Só se registra se foi
  -- resposta a quem falou por último (contato receptivo) ou contato ativo — para a medição, não para bloquear.
  select max(t.created_at) filter (where t.papel = 'lead'), max(t.created_at) filter (where t.papel in ('mari', 'humano'))
    into ult_lead, ult_out from public.mari_turnos t where t.conversa_id = c.id;
  resposta := ult_lead is not null and ult_lead > now() - interval '24 hours'
              and (ult_lead > coalesce(ult_out, '-infinity'::timestamptz)
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and a.payload ->> 'conta' = 'nao' and a.criada_em > ult_lead and a.criada_em > now() - interval '30 minutes'));
  -- Janela de 24 h: é regra do WhatsApp (a Meta recusa texto livre depois dela), não do contrato. Fechada → só template aprovado.
  if p_template is not null then
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and nome like 'nio\_%';
    if v_tpl.nome is null then raise exception 'Template não aprovado: %', p_template; end if;
    if (select count(*) from regexp_matches(coalesce(v_tpl.corpo, ''), '\{\{[0-9]+\}\}', 'g')) > 1 then
      raise exception 'Este template precisa de mais dados; mande pelo Chatwoot.';
    end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só template aprovado. Escolha um em "Respostas rápidas › Templates".' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', case when resposta then 'nao' else 'sim' end, 'rotulo', 'resposta do time');

  -- Sem dono → assume antes (a Mari cala, a cadência para).
  if c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false) then
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' ao responder — cadência parada]', false);
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', c.venda_id, c, 'atribuir',
      case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
    assumiu := true;
  end if;
  o := o + 1;
  aid := public._bo_enfileirar(g, o, 'responder', c.venda_id, c, 'mensagem', v_pay);
  return jsonb_build_object('ok', true, 'acao_id', aid, 'resposta', resposta, 'assumiu', assumiu,
    'resumo', '✓ mensagem enviada' || case when assumiu then ' · conversa assumida (a Mari calou)' else '' end);
end;
$function$;

-- backoffice_conversa_espera: corpo da produção (md5 42d4538f…) + a conferência da porta
CREATE OR REPLACE FUNCTION public.backoffice_conversa_espera__nucleo(p_conversa uuid, p_ate date, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare

  c       public.mari_conversas;

  g       uuid := gen_random_uuid();

  quem    text;

  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');

  v_ate   timestamptz;

  v_mot   text := nullif(left(btrim(coalesce(p_motivo, '')), 80), '');

  tem_cw  boolean;

  feito   text[] := '{}';

begin

  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then

    raise exception 'Só admin ou backoffice.' using errcode = '42501';

  end if;

  select * into c from public.mari_conversas where id = p_conversa for update;

  if not found then raise exception 'Conversa não encontrada.'; end if;

  if c.venda_id is not null then raise exception 'Esta conversa já tem venda: use a Pendência (⏸) da venda.'; end if;
  perform public._porta_conferir('aguardar', c.id, null::uuid);   -- 0275 (mapa situação × botão)

  select nome into quem from public.usuarios where id = auth.uid();

  quem := coalesce(quem, 'time');

  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';



  if p_ate is null then   -- Retomar agora

    if c.espera_ate is null then return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava em espera.'); end if;

    update public.mari_conversas set espera_ate = null, espera_motivo = null, espera_em = null, espera_por = null where id = c.id;

    insert into public.mari_turnos (conversa_id, papel, texto, pendente)

    values (c.id, 'sistema', '[espera encerrada no NIOGEN por ' || quem || ']', false);

    feito := feito || 'de volta no Live'::text;

    if tem_cw then

      perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content', '▶ Espera encerrada por ' || quem || ' em ' || agora_t || '.'));

      perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver', jsonb_build_object('status', 'open'));

      feito := feito || 'nota'::text || 'conversa reaberta'::text;

    end if;

    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ espera encerrada: a conversa volta para o Live');

  end if;



  if p_ate <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Escolha uma data a partir de amanhã.'; end if;

  if p_ate > (now() at time zone 'America/Sao_Paulo')::date + 60 then raise exception 'No máximo 60 dias.'; end if;

  v_ate := (p_ate::text || ' 09:00')::timestamp at time zone 'America/Sao_Paulo';

  update public.mari_conversas

     set espera_ate = v_ate, espera_motivo = coalesce(v_mot, 'aguardando o cliente'), espera_em = now(), espera_por = auth.uid()

   where id = c.id;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)

  values (c.id, 'sistema', '[em espera até ' || to_char(p_ate, 'DD/MM') || ' — ' || coalesce(v_mot, 'aguardando o cliente') || ' — marcado no NIOGEN por ' || quem || ']', false);

  feito := feito || ('fora do Live até ' || to_char(p_ate, 'DD/MM') || ' às 9h')::text;

  if tem_cw then

    perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content',

      '⏸ Em espera até ' || to_char(p_ate, 'DD/MM') || ' — ' || coalesce(v_mot, 'aguardando o cliente') || ' (' || quem || ', ' || agora_t

      || '). Volta para o Live no dia, ou antes se o cliente escrever.'));

    perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver',

      jsonb_build_object('status', 'snoozed', 'snoozed_until', extract(epoch from v_ate)::bigint));

    feito := feito || 'nota'::text || ('adiada no Chatwoot até ' || to_char(p_ate, 'DD/MM'))::text;

  end if;

  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),

    'resumo', '✓ em espera até ' || to_char(p_ate, 'DD/MM') || ' — volta antes se o cliente escrever');

end;

$function$;

commit;
