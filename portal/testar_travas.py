#!/usr/bin/env python3
# NIOGEN | portal/testar_travas.py | 11/11/2026 — Claude Code (docs/Prompt_operador_credito_consulta_111126_1650.md)
# Testa as travas do operador de crédito SEM navegador: lista negra de clique, Avançar proibido na Etapa 5, padrões de
# rede (casam com o que é proibido e NÃO casam com o que a consulta precisa), CPF, máscara, classificação e redação.
# 13/11/2026 — + seção 6: operador de OS (consulta_os.py), lista BRANCA de clique e de rede.
# Uso: python portal/testar_travas.py   → "VERDE" e código 0, ou a lista do que falhou e código 1.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:  # noqa: BLE001
    pass
import credito as cr  # noqa: E402

FALHAS = []


def ok(cond, nome):
    print(('  ok   ' if cond else '  FALHOU ') + nome)
    if not cond:
        FALHAS.append(nome)


def levanta(fn, nome):
    try:
        fn()
    except cr.TravaAcionada:
        ok(True, nome)
        return
    ok(False, nome)


class Alvo:
    """Imita um locator do Playwright: só texto e clique."""

    def __init__(self, texto):
        self.texto = texto
        self.clicado = False

    def inner_text(self, timeout=None):
        return self.texto

    def get_attribute(self, nome, timeout=None):
        return None

    def click(self, timeout=None):
        self.clicado = True


print('1. Clique — lista negra e etapa')
for t in ('Salvar interesse', 'Salvar Interesse', '  SALVAR   INTERESSE ', 'Abrir OS', 'Enviar', 'Finalizar',
          'Confirmar pedido', 'Carregar Pedido', 'Reenviar link'):
    a = Alvo(t)
    levanta(lambda a=a: cr.clicar(a, 2), f'recusa "{t.strip()}"')
    ok(not a.clicado, f'"{t.strip()}" não foi clicado')
a = Alvo('Avançar')
levanta(lambda: cr.clicar(a, 5), 'Avançar na Etapa 5 levanta exceção')
ok(not a.clicado, 'Avançar na Etapa 5 não foi clicado')
levanta(lambda: cr.clicar(Alvo('AVANCAR'), 5), 'AVANCAR (sem cedilha) na Etapa 5 levanta exceção')
levanta(lambda: cr.clicar(Alvo('Avançar'), None), 'Avançar com etapa desconhecida levanta exceção')
for n in (1, 2, 3, 4):
    a = Alvo('Avançar')
    cr.clicar(a, n)
    ok(a.clicado, f'Avançar permitido na Etapa {n}')
for t in ('Continuar', 'Buscar', 'Novo Pedido', 'Tentar novamente'):
    a = Alvo(t)
    cr.clicar(a, 3)
    ok(a.clicado, f'"{t}" permitido')

print('2. Rede')
for c in ('api/portal/aberturaos/checkout/enviar', 'api/portal/biometria/envio', 'api/portal/pagamento/reenviolink',
          'api/portal/carrinho/itens', 'api/portal/dadosBancarios/x', 'api/portal/portabilidade'):
    ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/' + c + '?a=1', 'POST', 'fetch')), f'barra {c}')
    ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/' + c, 'GET', 'xhr')), f'barra {c} (GET xhr)')
for c in ('api/portal/novafibra/analiseCredito', 'api/portal/novafibra/ofertas', 'api/portal/novafibra/cadastroCliente/consult',
          'api/portal/novafibra/endereco', 'api/portal/viabilidades/v2/abc', 'api/portal/permissoes'):
    ok(cr.rede_bloqueada('https://pap-api.niointernet.com.br/' + c, 'POST', 'fetch', pos_etapa2=True) is None,
       f'deixa passar {c}')
for c in ('api/portal/interesse/salvar', 'api/portal/prevenda', 'api/portal/novafibra/preVenda/1', 'api/x/SAVE_LEAD'):
    ok(cr.rede_bloqueada('https://pap-api.niointernet.com.br/' + c, 'POST', 'fetch', pos_etapa2=False) is None,
       f'{c} passa ATÉ a Etapa 2')
    ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/' + c, 'POST', 'fetch', pos_etapa2=True)),
       f'{c} barrado DEPOIS da Etapa 2')
ok(cr.rede_bloqueada('https://pap.niointernet.com.br/static/js/checkout.chunk.js', 'GET', 'script') is None,
   'script estático com "checkout" no nome não é pedido (passa)')
ok(cr.rede_bloqueada('https://pap-api.niointernet.com.br/api/portal/novafibra/portabilidadenovafibra/consultaDDDPorUF/MG', 'GET', 'xhr', True) is None,
   'GET consultaDDDPorUF/MG (lista de DDDs da Etapa 5) passa')
ok(cr.rede_bloqueada('https://pap-api.niointernet.com.br/api/portal/novafibra/portabilidadenovafibra/consultaOperadoras', 'GET', 'xhr', True) is None,
   'consultaOperadoras (lista de operadoras da Etapa 5) passa')
ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/api/portal/novafibra/portabilidadenovafibra/consultaOperadoras/a/b', 'GET', 'xhr', True)),
   'consulta com caminho mais fundo continua barrada')
ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/api/portal/novafibra/portabilidadenovafibra', 'POST', 'xhr', True)),
   'POST na portabilidade (sem consulta) continua barrado')
ok(bool(cr.rede_bloqueada('https://pap-api.niointernet.com.br/api/portal/novafibra/portabilidadenovafibra/solicitar', 'GET', 'xhr', True)),
   'outra rota de portabilidade (GET) continua barrada')
ok(cr.caminho_de('https://x.com/a/b?cpf=1') == 'a/b', 'caminho sem query (o log nunca leva a query)')

print('3. CPF e privacidade')
ok(cr.cpf_valido('529.982.247-25'), 'CPF válido aceito')
ok(not cr.cpf_valido('529.982.247-24'), 'dígito errado recusado')
ok(not cr.cpf_valido('111.111.111-11'), 'repetido recusado')
ok(cr.cpf_mascara('52998224725') == '529.***.***-25', 'máscara 123.***.***-09')
ok(cr.cpf_chave('52998224725', 's1') != cr.cpf_chave('52998224725', 's2'), 'hash depende do sal')
ok('52998224725' not in cr.sem_pii('erro em 52998224725 e a@b.com.br'), 'sem_pii tira CPF')
ok('a@b.com.br' not in cr.sem_pii('erro em 52998224725 e a@b.com.br'), 'sem_pii tira e-mail')
r = cr.redigir({'cpf': '1', 'nomeCliente': 'X', 'status': 'APROVADO', 'dados': [{'emailContato': 'a@b', 'codigo': 7}]})
ok(r['cpf'] == '<redigido>' and r['nomeCliente'] == '<redigido>' and r['status'] == 'APROVADO'
   and r['dados'][0]['emailContato'] == '<redigido>' and r['dados'][0]['codigo'] == 7, 'amostra redige PII e mantém status')

r2 = cr.redigir({'sexo': 'Masculino', 'statusInteresse': 'PROPOSTA_CONSULTADA', 'cep': '1', 'logradouro': 'x'})
ok(r2['sexo'] == '<redigido>' and r2['cep'] == '<redigido>' and r2['logradouro'] == '<redigido>'
   and r2['statusInteresse'] == 'PROPOSTA_CONSULTADA', 'amostra redige sexo/cep/logradouro e mantém o status da proposta')

print('4. Classificação')
ok(cr.classificar_popup('Pedido encontrado', 'Não é possível abrir um novo pedido, pois já existe outro pedido (Nova Fibra) em andamento para este cliente.', 3)
   == 'pedido_em_andamento', 'Pedido encontrado → pedido_em_andamento')
ok(cr.classificar_popup('OPS, OCORREU UM ERRO!', '', 3) == 'receita_retry', 'erro da Receita na Etapa 3 → nova tentativa')
ok(cr.classificar_popup('Crédito', 'Cliente não aprovado na análise', 5) == 'negado', 'não aprovado → negado')
ok(cr.classificar_popup('Análise', 'Aguarde 24 h', 5) == 'pendente', 'aguarde 24 h → pendente')
ok(cr.classificar_popup('Atenção!', 'Não é possível utilizar o telefone de contato informado pois excede a quantidade de repetições de mesmo número permitidas. Informe outro número para prosseguir.', 4)
   == 'contato_repetido', 'celular repetido na Etapa 4 → contato_repetido')
ok(cr.classificar_popup('Atenção!', 'E-mail inválido. Por favor preencha um e-mail válido para prosseguir.', 4)
   == 'email_invalido', 'e-mail recusado na Etapa 4 → email_invalido')
ok(cr.classificar_popup('Resultado da análise de crédito', 'Resultado da análise de crédito Crédito aprovado Elegível para todas as formas de pagamento Clique em Continuar para enviar ao cliente o link para Biometria, ou em Consultar outro CPF/CNPJ. Continuar Consultar outro CPF/CNPJ', 4)
   == 'aprovado_todas', 'popup "Crédito aprovado · todas as formas" → aprovado_todas')
ok(cr.classificar_popup('Resultado da análise de crédito', 'Crédito aprovado Elegível somente para cartão de crédito', 4) == 'aprovado_cartao', 'aprovado só cartão → aprovado_cartao')
ok(cr.classificar_popup('Resultado da análise de crédito', 'Crédito não aprovado', 4) == 'negado', '"Crédito não aprovado" continua negado')
ok(cr.classificar_popup('Aviso', 'Algo novo', 5) == 'nao_classificado', 'outro → nao_classificado')
ok(cr.tem_numero('Rua Elder Gonçalves De Souza, 52 - Conjunto', '52'), 'endereço: escolhe a opção com o número 52')
ok(not cr.tem_numero('Rua Elder Gonçalves De Souza, 520 - Conjunto', '52'), 'endereço: não confunde 520 com 52')
ok(not cr.tem_numero('Rua 52, 10 - Centro', '5'), 'endereço: não pega dígito de outro número')
ok(cr.escolher_opcao(['CASA A', 'CASA B', 'APTO 101'], 'casa b') == 'CASA B', 'complemento: "casa b" escolhe CASA B')
ok(cr.escolher_opcao(['CASA A', 'CASA B'], 'Casa  A') == 'CASA A', 'complemento: ignora caixa e espaços')
ok(cr.escolher_opcao(['APTO 101 BL 1', 'APTO 102 BL 1'], '101') == 'APTO 101 BL 1', 'complemento: "101" escolhe a única que contém')
ok(cr.escolher_opcao(['CASA A', 'CASA B'], 'CASA') is None, 'complemento: ambíguo não escolhe')
ok(cr.escolher_opcao(['CASA A'], 'FUNDOS') is None, 'complemento: fora da lista não escolhe')
APTOS = ['Apartamento 101', 'Apartamento 102', 'Apartamento 103', 'Apartamento 301', 'Apartamento 302', 'Apartamento 1403']
ok(cr.escolher_opcao(APTOS, '403') is None, 'complemento: 403 fora da lista não vira 1403 (unidade nunca é trocada)')
ok(cr.escolher_opcao(APTOS, '03') is None, 'complemento: "03" não vira 103')
ok(cr.escolher_opcao(APTOS, '302') == 'Apartamento 302', 'complemento: "302" escolhe Apartamento 302')
ok(cr.escolher_opcao(APTOS, 'apto 302') is None, 'complemento: "apto 302" (escrita diferente) não escolhe sozinho → botões')
ok(cr.classificar_formas(['BOLETO', 'CREDITO', 'DACC']) == 'aprovado_todas', '3 formas → aprovado_todas')
ok(cr.classificar_formas(['CREDITO']) == 'aprovado_cartao', 'só cartão → aprovado_cartao')
ok(cr.classificar_formas(['BOLETO', 'CREDITO']) == 'aprovado_parcial', 'subconjunto → aprovado_parcial')
o = cr.ler_oferta('Nio Essencial\n800 Mega\nR$ 140,00/mês\nCom fidelidade')
ok(o == {'nome': 'Nio Essencial', 'velocidade': '800 Mega', 'preco': 'R$ 140,00', 'fidelidade': True}, 'lê cartão de oferta')

print('4b. Modo duplicidade (12/11, Mari): para na Etapa 3, nunca chega ao contato nem ao crédito')
for modo in ('duplicidade', 'viabilidade'):
    c = cr.Consulta(None, {'modo': modo, 'origem_endereco': 'padrao', 'cpf': None}, {})
    try:
        c.etapa4()
        ok(False, f'modo {modo}: etapa4() recusa')
    except cr.Parar as p:
        ok(p.resultado == 'erro' and 'bloqueado' in str(p.extra.get('motivo', '')), f'modo {modo}: etapa4() recusa (Parar erro)')
    except Exception as e:  # noqa: BLE001
        ok(False, f'modo {modo}: etapa4() recusa — levantou {type(e).__name__}')
ok('sem_pedido_em_andamento' in cr.RESULTADOS, 'sem_pedido_em_andamento é resultado conhecido')
ok(cr.Consulta(None, {'origem_endereco': 'padrao', 'cpf': None}, {}).modo == 'credito', 'sem modo = crédito (consulta da tela)')

print('5. JS injetado na página (sintaxe, se houver node)')
import shutil, subprocess, tempfile
if shutil.which('node'):
    for nome in ('POPUP_JS', 'RADIOS_JS', 'OFERTAS_JS', 'ENDERECO_JS', 'NOME_JS', 'ETAPA_JS', 'ENDERECO_OPCOES_JS'):
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
            f.write('const f = ' + getattr(cr, nome) + ';')
        r = subprocess.run(['node', '--check', f.name], capture_output=True)
        os.unlink(f.name)
        ok(r.returncode == 0, f'{nome} compila')
else:
    print('  (sem node: pulado)')

print('6. Operador de OS — Consulta OS (13/11): lista BRANCA de clique e de rede, e nenhum dado pessoal na leitura')
import consulta_os as co  # noqa: E402
for t_ in ('Filtros', 'Filtrar', '  FILTRAR ', 'filtros'):
    a = Alvo(t_)
    co.clicar(a)
    ok(a.clicado, f'"{t_.strip()}" permitido')
for t_ in ('Detalhar', 'Atualizar o status da OS', 'Enviar link de pagamento', 'Reenviar link de pagamento', 'Agendar instalação',
           'Reagendar', 'Cancelar OS', 'Salvar', 'Atualizar Pedido', 'Carregar pedido', 'Novo Pedido', 'Sair', 'Filtrar e salvar', ''):
    a = Alvo(t_)
    levanta(lambda a=a: co.clicar(a), f'recusa "{t_}"')
    ok(not a.clicado, f'"{t_}" não foi clicado')
API = 'https://pap-api.niointernet.com.br/'
ok(co.rede_bloqueada(API + 'api/portal/novafibra/consultastatusos?startDate=1&cpf=2&orderId=3', 'GET', 'xhr') is None, 'GET consultastatusos passa')
ok(bool(co.rede_bloqueada(API + 'api/portal/novafibra/consultastatusos', 'POST', 'xhr')), 'POST consultastatusos é barrado')
ok(bool(co.rede_bloqueada(API + 'api/portal/novafibra/consultastatusos/atualizar', 'GET', 'xhr')), 'rota mais funda de consultastatusos é barrada')
for c in ('manutencao?x=1', 'auth/user/info', 'api/portal/permissoes', 'api/portal/permissoes/skills'):
    ok(co.rede_bloqueada(API + c, 'GET', 'xhr') is None, f'sessão: GET {c.split("?")[0]} passa')
ok(co.rede_bloqueada(API + 'api/portal/loginbo', 'POST', 'xhr') is None, 'sessão: loginbo passa (a página confere o login ao abrir)')
for c in ('api/portal/pagamento/reenviolink', 'api/portal/novafibra/reenviolinkpagamento', 'api/portal/novafibra/agendamento',
          'api/portal/novafibra/reagendamento', 'api/portal/novafibra/cancelamentoos', 'api/portal/novafibra/atualizastatusos',
          'api/portal/aberturaos/checkout/enviar', 'api/portal/historico', 'api/portal/novafibra/analiseCredito',
          'api/portal/gestao/usuario', 'api/portal/powerbi/embed-info'):
    ok(bool(co.rede_bloqueada(API + c, 'GET', 'xhr')), f'barra GET {c}')
    ok(bool(co.rede_bloqueada(API + c, 'POST', 'fetch')), f'barra POST {c}')
ok(bool(co.rede_bloqueada(API + 'api/portal/permissoes', 'POST', 'xhr')), 'POST em rota de sessão é barrado')
ok(co.rede_bloqueada('https://pap.niointernet.com.br/administrativo/consulta-os', 'GET', 'document') is None, 'abrir a tela (GET no front) passa')
ok(co.rede_bloqueada('https://pap.niointernet.com.br/static/js/bundle.js', 'GET', 'script') is None, 'script do front passa')
ok(bool(co.rede_bloqueada('https://pap.niointernet.com.br/qualquer', 'POST', 'fetch')), 'POST no front é barrado')
ok(co.rede_bloqueada('https://browser-intake-datadoghq.com/api/v2/rum?x=1', 'POST', 'fetch') is None, 'telemetria de outro host não é pedido ao portal (passa)')
ok(bool(co.rede_bloqueada('https://outro.exemplo.com/api/pagamento/reenviolink', 'POST', 'fetch')), 'pagamento em qualquer host é barrado')
RESP = {'codigo': 2000, 'mensagem': 'Sucesso', 'data': [{
    'idVenda': 'abc', 'addressId': '1', 'statusOS': 'Em Aprovisionamento', 'numeroOS': '90000001', 'plano': 'Nio Fibra',
    'statusAgendamento': 'Concluído com sucesso', 'agendamento': '13/11/2026 - 08:00 às 12:00', 'pendencia': '', 'caseNumber': '',
    'motivoCancelamento': '-', 'subMotivoCancelamento': '-', 'numeroBA': 'SA-1', 'idSalesforce': 'x',
    'clientEmail': 'pessoa@exemplo.com.br', 'clientPhoneWhatsapp': '32999990000', 'attendancePdv': 'PDV X',
    'reenvioLinkPagamentoHabilitado': False}]}
r = co.ler_resposta(RESP, '90000001')
ok(r['resultado'] == 'lida' and r['leitura'] == {'status_ordem': 'Em Aprovisionamento', 'status_agendamento': 'Concluído com sucesso',
   'agendamento': '13/11/2026 - 08:00 às 12:00', 'numero_ba': 'SA-1'}, 'lê status, agendamento e BA; vazio e "-" não entram')
ok('exemplo.com' not in str(r) and '32999990000' not in str(r) and 'PDV X' not in str(r) and 'abc' not in str(r),
   'e-mail, telefone, PDV e ids internos do cliente não saem da leitura')
RESP['data'][0].update(statusOS='Cancelado', motivoCancelamento='Inviabilidade Total', subMotivoCancelamento='Sem rede', pendencia='LOCAL FECHADO')
r = co.ler_resposta(RESP, '90000001')
ok(r['leitura']['motivo_cancelamento'] == 'Inviabilidade Total · Sem rede' and r['leitura']['pendencia'] == 'LOCAL FECHADO', 'lê motivo de cancelamento e pendência')
ok(co.ler_resposta(RESP, '90000002')['resultado'] == 'nao_encontrada', 'OS que não veio na resposta → nao_encontrada (não lê a OS de outro)')
ok(co.ler_resposta({'codigo': 2000, 'data': []}, '90000001')['resultado'] == 'nao_encontrada', 'lista vazia → nao_encontrada')
ok(co.ler_resposta({'erro': 'x'}, '90000001')['resultado'] == 'erro', 'resposta fora do formato → erro')
ok(co.ler_resposta({'data': [{'numeroOS': '90000001', 'statusOS': '-'}]}, '90000001')['resultado'] == 'erro', 'sem status → erro (não grava leitura vazia)')

print()
if FALHAS:
    print(f'VERMELHO — {len(FALHAS)} falha(s)')
    sys.exit(1)
print('VERDE — todas as travas conferidas')
