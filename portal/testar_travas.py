#!/usr/bin/env python3
# NIOGEN | portal/testar_travas.py | 11/11/2026 — Claude Code (docs/Prompt_operador_credito_consulta_111126_1650.md)
# Testa as travas do operador de crédito SEM navegador: lista negra de clique, Avançar proibido na Etapa 5, padrões de
# rede (casam com o que é proibido e NÃO casam com o que a consulta precisa), CPF, máscara, classificação e redação.
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
ok(cr.classificar_popup('Aviso', 'Algo novo', 5) == 'nao_classificado', 'outro → nao_classificado')
ok(cr.classificar_formas(['BOLETO', 'CREDITO', 'DACC']) == 'aprovado_todas', '3 formas → aprovado_todas')
ok(cr.classificar_formas(['CREDITO']) == 'aprovado_cartao', 'só cartão → aprovado_cartao')
ok(cr.classificar_formas(['BOLETO', 'CREDITO']) == 'aprovado_parcial', 'subconjunto → aprovado_parcial')
o = cr.ler_oferta('Nio Essencial\n800 Mega\nR$ 140,00/mês\nCom fidelidade')
ok(o == {'nome': 'Nio Essencial', 'velocidade': '800 Mega', 'preco': 'R$ 140,00', 'fidelidade': True}, 'lê cartão de oferta')

print('5. JS injetado na página (sintaxe, se houver node)')
import shutil, subprocess, tempfile
if shutil.which('node'):
    for nome in ('POPUP_JS', 'RADIOS_JS', 'OFERTAS_JS', 'ENDERECO_JS', 'NOME_JS'):
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
            f.write('const f = ' + getattr(cr, nome) + ';')
        r = subprocess.run(['node', '--check', f.name], capture_output=True)
        os.unlink(f.name)
        ok(r.returncode == 0, f'{nome} compila')
else:
    print('  (sem node: pulado)')

print()
if FALHAS:
    print(f'VERMELHO — {len(FALHAS)} falha(s)')
    sys.exit(1)
print('VERDE — todas as travas conferidas')
