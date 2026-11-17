# Portão dos fluxos

Bateria de cenários do lead (nascimento → venda → saída) rodada numa **cópia local** do banco, com um Chatwoot de mentira.
Nunca toca a produção: não abre conexão com a Supabase, e o envio para n8n, Chatwoot e cliente é simulado.

- `copia_local.sh` — restaura o backup diário mais recente num PostgreSQL 17 local (porta 54329, só 127.0.0.1).
- `sim.sql` — o simulador (esquema `sim`): Chatwoot com as 3 automações da conta, fila do backoffice, guard da Mari,
  cadência, relógio e as regras gerais conferidas no fim de todo cenário (R1–R7, S1–S5).
- `cenarios/*.sql` — um cenário por arquivo (`-- id`, `-- titulo`, `-- tipo: atual | regra_nova`).
- `portao.py` — roda tudo, cada cenário numa cópia descartável.

```bash
tests/fluxos/copia_local.sh
python tests/fluxos/portao.py
python tests/fluxos/portao.py --trilha C8
```

A cópia tem dado de cliente: fica em `~/niogen_sim`, fora do repo e do Drive.
