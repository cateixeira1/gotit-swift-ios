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
  IME nunca é interceptada. Falta validar em aparelho. **Seleção entre páginas**
  (9fdbee9): continua um `UITextView` por página; numa história com mais de uma
  página, uma seleção vira seleção da história, com destaque próprio em cada
  página e duas alças arrastáveis para outras páginas (rolagem perto das bordas).
  Digitar, apagar, colar, recortar, copiar (texto e RTF), formatar e "Selecionar
  tudo" agem sobre a história inteira, editada como um texto só e redistribuída
  num único desfazer (`StoryEditing`). Testes nativos de edição, desfazer e
  destaque/alças; arrastar as alças só no aparelho. Não afirmar equivalência com Word.
- **Reflow ao mover obstáculos conectado** (commit 7ec3fb3): inserir, remover,
  mover, redimensionar, girar ou mudar o contorno de um objeto, redimensionar a
  caixa da própria história ou mudar o padrão de contorno do canvas redistribui
  as histórias afetadas no mesmo lote (um único desfazer). Traços e digitação não
  disparam. Detecção pura com testes; layout TextKit verificado só por compilação
  e testes de UI existentes, não em aparelho.
- Medir latência e memória em aparelho físico, especialmente histórias longas.
  **Medição no aparelho disponível** (08/11, commit 51c9e7d): menu da nota →
  "Medir desempenho do aparelho", com dados temporários; o usuário copia o
  resultado. O mesmo código roda no CI (simulador, build Debug, não é aparelho):
  antes da paginação incremental, uma tecla custava ~190 ms numa história de 34
  páginas e 30–37 ms numa de 12. **Paginação incremental** (1cd14dd): começa na
  página anterior à editada e para na primeira página que termina onde terminava;
  teste nativo compara 40 edições aleatórias com a paginação completa. Depois
  (b33b14b, simulador Debug): 37 páginas com parágrafos, tecla no fim mediana
  11 ms, no início 16 ms; parágrafo único de 34 páginas, mediana ~30 ms e p95
  ~320 ms. Gravação SQLite por tecla (30 páginas, fora da thread principal) mediana
  ~4 ms; fila de recuperação 0,3 ms; formas 23 ms por traço (eram 107 ms; busca do
  maior quadrilátero passou de O(n⁴) a O(n³)). Faltam os números do aparelho.
  O layout/diff do documento inteiro ainda é percorrido a cada edição (é o que resta
  nos ~11 ms); não há índice espacial incremental. Conexões e a camada PencilKit
  não usam o pool de views de blocos.
- **Fonte do sistema preservada** (a1b9ce3): o texto salvo guardava o nome
  interno da fonte do sistema (".SFUI-…"), que o CoreText não resolve por nome e
  substitui por outra fonte; ao redesenhar, as quebras de linha e de página mudavam
  (página 1 passava de 2.024 para 2.296 caracteres no teste). Agora esse nome não é
  guardado e, em notas existentes, é lido como a fonte do sistema.
- **Histórico limitado por bytes** (commit 072324f): `historyByteLimit`, padrão
  32 MiB por nota, além dos 50 grupos; a entrada mais recente é sempre mantida.
  **Desenho por partes** (9fdbee9): um gesto que só acrescenta traços grava só esses
  traços como mais uma parte (`AssetReference.parts`, até 24); apagar, mover ou
  converter traços, ou a 25.ª parte, grava o desenho inteiro e libera base e partes
  antigas. Notas antigas abrem sem mudança.
- **Fila de recuperação ligada ao app** (0b56315): ver a seção abaixo.
- **IME, colar e desfazer** (testes nativos, 0b56315/1cd14dd): o fim de uma
  composição (tecla morta, kana) passa a ser salvo na hora (antes podia esperar a
  próxima tecla) e relatos repetidos do mesmo texto contam uma vez; digitação
  agrupada e colagem como passo próprio; desfazer/refazer de uma colagem que criou
  páginas. Simulados no simulador; teclado real e IME no aparelho ainda por validar.
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


## Recuperação de gravações (08/11/2026)

Primeira tentativa (06/11): com a fila ligada ao host, o teste de interface de
desenho falhou 2 de 2 vezes no iPhone e a ligação foi removida (47ed923), sem
causa isolada. Segunda versão (0b56315):

- `PendingEditJournal` virou um log só de acréscimos (uma linha por edição ou por
  confirmação, esvaziado quando nada está pendente). Uma última linha cortada por
  queda é ignorada (sua edição ainda não tinha aparecido); qualquer outra linha
  danificada impede a leitura e o arquivo é preservado.
- O app grava cada edição na fila antes de mostrá-la e a retira depois do commit.
  Diferenças em relação à primeira tentativa: um problema na fila nunca bloqueia a
  edição (um aviso só), a fila em memória comanda a gravação, o documento salvo é
  aplicado antes de qualquer outro `await` e os recibos são apagados numa única
  transação quando a fila esvazia.
- Ao abrir, `replay(into:)` reaplica o que estava pendente usando os recibos: uma
  edição que o SQLite já tinha confirmado não é aplicada duas vezes. O que não puder
  ser aplicado vai para um arquivo à parte (`quarantine`), nunca é descartado.
- Testes: núcleo (reinício, linha cortada, recuperação única com edição já
  confirmada + duas pendentes, quarentena) e interface: com as gravações retidas
  (`--hold-saves`), uma página criada sobrevive ao app ser encerrado. O teste de
  desenho que falhava em 06/11 passou em iPad e iPhone com a fila ligada
  (execuções de 51c9e7d e b33b14b).
- Limite: cobre o app fechado ou encerrado; queda de energia no mesmo instante não
  (sem fsync por tecla). Não testado em aparelho.

O CI reexecuta uma vez um teste que falhe no simulador (`-retry-tests-on-failure`),
depois de uma falha de inicialização do XCUITest ("Failed to get background
assertion"); a primeira falha fica no pacote de resultados.

A estratégia de retomada dos recursos adiados está em [workflow.md](workflow.md).
Teia entra após catálogo/indexação; equações após estabilização da tinta e
validação do reconhecimento, com reavaliação na inteligência local se necessário.
