# Revisão da etapa 2 — 06/11/2026

**Status: aberta.** O commit remoto auditado foi
`fcbf017f33f72253ff865cc3d1d54979973ba6d3`, branch
`codex/stage-2-canvas-engine`, PR #1. A documentação daquele commit já dizia
explicitamente que a etapa 2 não estava encerrada. Esta revisão substitui a
sequência de prioridades dos documentos anteriores. Teia, resolvedor de equações
e ampliação do reconhecimento permanecem congelados.

## Alterações preparadas

1. **Histórico e digitação.** Deltas estruturais bidirecionais; texto usa splice
   por `Character`, preservando emoji e caracteres combinados. Comparações de
   valores Swift evitam serializar blocos inalterados na construção do delta.
   Transações passam a atualizar apenas as linhas modificadas. Um cache de uma
   nota verifica revisão/metadados sob o lock SQLite antes de evitar releituras.
   A UI agrupa digitação consecutiva por posição, bloco, pausa de 1 s e duração
   máxima de 5 s. Colagem, mudança de posição e formatação separam operações.
   Uma operação não textual e um ramo novo após undo também separam grupos.
2. **Desenhos.** Substituição remove o registro da versão anterior quando nenhum
   bloco o utiliza. A coleta considera todas as notas, derivados e estados
   alcançáveis pelo histórico de undo e redo. Arquivos órfãos com mais de 24 h
   são recolhidos em checkpoints ociosos, no máximo uma vez a cada 5 min.
   Migração de bancos antigos poda metadados PencilKit sem referências tanto
   nos estados históricos quanto no estado atual. Arquivos PencilKit continuam
   sendo snapshots completos por gesto, mas a retenção não cresce indefinidamente.
3. **Texto entre páginas.** Novos blocos textuais de raiz em notas recebem um
   identificador de história. TextKit mede glifos, fontes e exclusões, cria
   páginas de continuação, redistribui rich text após edição e transfere a posição
   de edição ao fragmento correspondente. Páginas geradas que ficaram vazias são
   removidas apenas se não contiverem outros objetos. Caixas antigas e textos
   internos de formas continuam independentes; não são migrados silenciosamente.
4. **Views.** Objetos fora do overscan são retirados da hierarquia e seus dados
   descartados; pools limitados a 12 textos e 24 objetos. Foco/IME, seleção e
   arraste ficam fixos até terminar a interação. Imagens têm NSCache de 32 MiB.
   Foram acrescentadas quatro alças de redimensionamento. Os menus de recorte
   continuam numéricos.
5. **Prumo.** Componentes extraídos do leitor no commit
   `5334bbaa274fe4a28c7e3d74b4382922d06804f6` de `cateixeira1/prumo-pdf-ios`,
   com licença MIT preservada em `licenses/Prumo-MIT.txt`. PDF abre em leitor
   com todas as páginas, miniaturas, busca, seleção e marca-texto, além de
   desfazer/refazer dos destaques. Salvar cria um novo asset e uma operação
   reversível na nota; cancelar preserva o original. Não inclui as ferramentas
   de OCR, assinatura, organização, resumo e processamento em lote do Prumo.
6. **Aplicativo.** Host promovido de `Examples/GotItDemo` para `Apps/GotIt`,
   alvo `GotItApp`, com configuração Mac Catalyst. Bundle ID e diretório de dados
   anteriores preservados. Isso ainda não é distribuição assinada/TestFlight.
   O produto SPM `GotItCanvasUI` continua UIKit; macOS utiliza o alvo Catalyst,
   não um editor AppKit.

## Verificação disponível

- 51 testes do núcleo passaram em Swift 6.0.3/Linux após as alterações.
- Regressões novas: 80 edições numa nota com bloco vizinho de 800 mil caracteres
  ocupam um grupo; o bloco vizinho não recebe UPDATE; deltas somados ficam abaixo
  de 80 KB; undo/redo sobrevive ao restart; Unicode; descarte do ramo redo;
  assets permanecem somente enquanto o estado atual/histórico precisa deles.
- Migração de snapshots v1/v2/v3 para deltas, rollback de falhas e concorrência
  entre conexões continuam cobertos. O esquema passa a v5.
- CI do commit `693d1785ce2bb991d20e100dcc258ec828d1aadd` aprovado:
  https://github.com/cateixeira1/gotit-swift-ios/actions/runs/42255842252
- 51 testes do núcleo em Linux/macOS; compilação iOS e Mac Catalyst aprovadas.
- Em cada simulador (iPad e iPhone): 5 testes nativos e 1 teste de interface
  passaram, incluindo paginação, limite de views, PDF multipágina e desenho/reabertura.
- Publicação autorizada pelo usuário e realizada na branch do PR #1.
  O bloqueio anterior de aprovação foi resolvido. A etapa permanece aberta
  pelos critérios funcionais abaixo; aprovação do CI não equivale a conclusão.

## Critérios que impedem o encerramento

- Validar transferência do cursor, IME, teclado e desfazer após reflow no iPad e
  iPhone. **Backspace na fronteira implementado** (commit 4cb299b): na posição 0
  de um fragmento de continuação, apaga o último caractere (emoji/combinação
  inteiros) do fragmento anterior, pula páginas vazias e redistribui; composição
  IME nunca é interceptada. Falta validar em aparelho. **Seleção única entre
  fragmentos continua não implementada**: cada página é um `UITextView`; exige
  mudar a arquitetura de texto. Não afirmar equivalência com Word.
- **Reflow ao mover obstáculos conectado** (commit 7ec3fb3): inserir, remover,
  mover, redimensionar, girar ou mudar o contorno de um objeto, redimensionar a
  caixa da própria história ou mudar o padrão de contorno do canvas redistribui
  as histórias afetadas no mesmo lote (um único desfazer). Traços e digitação não
  disparam. Detecção pura com testes; layout TextKit verificado só por compilação
  e testes de UI existentes, não em aparelho.
- Medir latência e memória em aparelho físico, especialmente histórias longas.
  O layout/diff ainda percorre o documento; não há índice espacial incremental.
  Conexões e a camada PencilKit não usam o pool de views de blocos.
- **Histórico limitado por bytes** (commit 072324f): `historyByteLimit`, padrão
  32 MiB por nota, além dos 50 grupos; a entrada mais recente é sempre mantida.
  Deltas de traços PencilKit (em vez de snapshot por gesto) continuam pendentes.
- Persistir fila de comandos pendentes para recuperação de encerramento abrupto:
  reaberto (ver abaixo).
- **Recorte com alças** (efef958): "Recortar com alças" usa os quatro cantos para
  aparar ou revelar a imagem sem mover nem reescalar os pixels visíveis, nunca
  além do original; o diálogo numérico continua como "Recorte exato (%)".
- **Imagem dentro de forma** (a5711b2): `imageMask` recorta imagem/adesivo em
  elipse, losango ou triângulo; o contorno de texto segue a máscara.
- **Estilos nomeados** (c2dee63): Título, Subtítulo, Título 1, Título 2, Corpo e
  Citação, com redefinição por nota e estilos próprios. Aplicar age sobre os
  parágrafos da seleção; "Atualizar estilo pela seleção" muda todas as ocorrências
  num único desfazer e preserva formatação manual. Os trechos guardam atributos
  concretos e só uma etiqueta do estilo.
- **Tabelas simples** (9ddeaca, testes nativos ebdc226): células com texto rico,
  inserir/excluir linhas e colunas, linha de cabeçalho, cor de célula e espessura
  da borda; segundo toque edita a célula e a linha cresce para caber o texto.
  O quadro do bloco sempre corresponde à grade (validado). Sem mesclagem nem
  fórmulas, por decisão; ambos podem entrar como campos opcionais.

Verificação desta continuação: 92 testes do núcleo e 7 nativos em Swift 6.0.3/Linux
(toolchain oficial de swift.org) e CI completo aprovado em
https://github.com/cateixeira1/gotit-swift-ios/actions/runs/42298240690

A próxima entrega deve fechar esses critérios, sem retomar Teia/equações antes
que o núcleo de edição tenha sido validado.


## Continuação: recuperação de gravações (parcial)

O esquema v6 acrescenta recibos de operações na mesma transação do documento, e
`PendingEditJournal` oferece uma fila em arquivo atômico, ambos com testes. A
ligação dessa fila ao host (`GotItApp`) foi **desativada**: com ela, o teste de
interface de desenho falhou 2 de 2 vezes no iPhone (contador permanece em
"0 traços"), enquanto o commit anterior passou 3 de 3 e o mesmo código com a
ligação removida passou na execução 42268105571. A causa exata não foi isolada
(não há Xcode no ambiente de desenvolvimento); a evidência é correlacional.

Consequência: o critério "persistir fila de comandos pendentes para recuperação
de encerramento abrupto" continua **aberto**. Cada edição já é confirmada no
SQLite (WAL) em transação própria; o risco restante é a janela entre a edição
otimista e o commit. Reintroduzir a ligação somente com um teste de interface
que reproduza a falha e depois de depurá-la em simulador local.

A estratégia de retomada dos recursos adiados está em [workflow.md](workflow.md).
Teia entra após catálogo/indexação; equações após estabilização da tinta e
validação do reconhecimento, com reavaliação na inteligência local se necessário.
