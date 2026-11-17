# Workflow e critérios de retomada

Ordem revisada em 06/11/2026. Teia e equações são tarefas adiadas, não canceladas.
Sua retomada depende das bases abaixo estarem verificadas, sem pedir nova decisão
sobre prioridades a cada entrega.

| Ordem | Entrega | Critério de saída |
| --- | --- | --- |
| 1 | Integridade da edição: deltas, agrupamento, recuperação da fila | Undo/redo persistente, replay idempotente, corrupção preservada e falhas transacionais testadas |
| 2 | Texto contínuo e interação | Cursor/backspace e seleção entre páginas; reflow ao mover obstáculos; testes com IME, colagem e undo |
| 3 | Desempenho e multimídia | Views recicladas; orçamento de memória/histórico; assets com coleta segura; PDF integrado; validação em aparelho |
| 4 | Catálogo e memória semântica | Pastas e navegação persistentes; miniaturas por revisão; referências entre notas; indexação incremental |
| 5 | Inteligência local | Runtime e modelo medidos; propostas de comandos validadas; experiência offline |

## Reconhecimento de formas

Antecipado em 07/11/2026 a pedido do usuário, depois do teste em aparelho (só
convertia figuras quase perfeitas). Reescrito com múltiplos traços, segurar no fim
e regras de contexto para não converter escrita; detalhes e taxas medidas em
`native-editor.md`. Pendente: medir falsos positivos com traços reais do usuário
(exportar amostras do aparelho) e ajustar os limites com esses dados.

## Equações manuscritas

Preparar o corpus e o pipeline de reconhecimento no encerramento da multimídia
(etapa 3), após estabilizar a captura de tinta. Retomar a integração nessa janela
se a transcrição atingir os critérios definidos para o corpus, com correção
manual e preservação do original. Se a precisão não for suficiente, manter o
recurso fora da interface principal e reavaliar na etapa 5. O resolvedor
algébrico determinístico existente é reaproveitado; SLM não é pré-requisito.

## Teia

Retomar na etapa 4, depois de catálogo/pastas, miniaturas versionadas e referências
estáveis estarem prontos. Implementar seleção de Teias existentes, entradas na
nota/pasta/card e atualização de prévias. Depois integrar sugestões de relações
quando a indexação incremental estiver validada. O layout livre e as conexões
manuais não dependem da disponibilidade do SLM.

## Regra de execução

Recursos adiados não interrompem os critérios 1–3. Falhas de integridade, digitação,
seleção ou memória têm precedência sobre novas funções. Cada retomada deve ter
seu próprio conjunto de testes e limites documentados, sem reabrir a arquitetura
básica do editor.
