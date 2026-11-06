# Etapa 2 — Canvas Engine e contrato do editor

Requisitos do usuário incorporados em 06/11/2026. Esta etapa foi iniciada após
o Document Core. O código do motor foi testado em Linux; o adaptador UIKit e o
aplicativo de demonstração **ainda não foram compilados nem executados em um
ambiente Apple nesta entrega**. A etapa 2 não está encerrada.

## Requisitos, padrões e rastreabilidade

| Função | Comportamento acordado | Implementação atual |
| --- | --- | --- |
| Editor semelhante ao Word nas funções básicas | Seleção, copiar/recortar/colar, desfazer/refazer, fontes, tamanhos, negrito, itálico, sublinhado, tachado, cores, destaque, alinhamento, listas, recuos, espaçamento, links e localizar/substituir | Metadados persistentes e código UIKit; testes visuais pendentes. Tabelas simples e estilos nomeados estão no escopo restante |
| Texto contorna objetos | Ligado por padrão; adaptar ao espaço livre e permitir sobreposição por escolha do usuário | Motor de exclusões para formas, imagens, PDFs, stickers, áudio, vídeo e cards; adaptador para `NSTextContainer.exclusionPaths` |
| Diagramas desenhados | Reconhecimento ligado por padrão; formas geométricas proporcionais, com texto interno por padrão | Reconhecimento geométrico inicial de traço único; criação atômica de forma + texto; original preservado como pontos |
| Conteúdo das formas | Texto, cor e imagem; forma é um bloco composto | Modelo permite filhos textuais e imagens; preenchimento/borda com cores no adaptador; recorte de imagem pela silhueta ainda pendente |
| Conexões | Cor independente da forma; acompanhar suas mudanças | Conectores entre IDs de blocos, rotas reta/ortogonal, cor, espessura e seta; menu de cor/exclusão no adaptador |
| Canvas | A4 por padrão; dimensão livre em px, cm ou in; zoom | Conversões testadas; opções e zoom no código UIKit/SwiftUI |
| Imagens | Redimensionar, recortar e girar | Frame, recorte normalizado e rotação separados do original; menus de tamanho, recorte numérico e giro de 90°; importação simples no demo |
| Equações manuscritas | Reconhecer e resolver até segundo grau; permitir desligar | Resolvedor determinístico testado e toggle persistente; reconhecimento matemático da escrita **não integrado**; demo aceita expressão digitada/corrigida |
| Teia | Canvas com notas escolhidas, prévia, nome, criação, conexões, disposição livre, texto e detalhes | Cards referenciados por ID, cronologia derivada, conexões manuais, posições e texto; demo resolve metadados e prévias textuais |
| Entradas da Teia | Botão na nota, na pasta e no retângulo do ícone da nota | Demo tem entrada na nota, no card e na coleção geral; navegação por pastas reais ainda depende do catálogo de pastas |

O que consta como código UIKit não equivale a funcionalidade validada no aparelho.
A migração e a persistência dos modelos foram verificadas separadamente.

## Módulos e fronteiras

- `GotItDomain`: documentos, metadados editoriais, bloco composto, layout,
  recorte, traços, referências e preferências. Sem dependência de UI ou IA.
- `GotItPersistence`: SQLite, migração, comandos e histórico.
- `GotItCanvas`: posicionamento, zoom/coordenadas, exclusões, conectores,
  transformações, reconhecimento geométrico, equações e projeção da Teia.
- `GotItCanvasUI`: adaptador UIKit/TextKit 2 e ponte SwiftUI, isolados por
  `canImport(UIKit)`. O host injeta imagens, prévias e callbacks de persistência.
- `Examples/GotItDemo`: host de demonstração SwiftUI, com fila serial de
  comandos, banco local e importação inicial de imagens.

O demo aplica comandos a uma cópia em memória para responder à digitação,
enfileirando revisões esperadas. Só confirma a versão depois do commit SQLite.
Uma falha interrompe as gravações e avisa o usuário; essa fila ainda precisa de
recuperação durável para edições pendentes ao encerrar/suspender o processo.

## Texto e composição espacial

Uma nota continua sendo uma árvore de blocos com relações espaciais. Formas
fechadas também podem conter filhos. Traços e setas não são containers.
O modelo distingue atributos dos runs e do parágrafo. Listas são atributos
estruturais do parágrafo, não simples marcadores gravados no texto.

O contorno usa coordenadas do documento, converte obstáculos para coordenadas
locais do texto e considera o padding e a rotação dos objetos. O próprio
container de um texto não pode excluí-lo. O usuário pode escolher:

- Herdar o padrão da nota.
- Contorno retangular.
- Contorno geométrico de formas.
- Texto apenas acima e abaixo.
- Sobreposição sem exclusão.

Contorno de alpha real de imagem/sticker fica para o pipeline de derivados;
até lá, usa-se o retângulo. Os componentes de PDF/áudio/vídeo já reservam área
no layout, mas os respectivos visualizadores/players pertencem à etapa 3.

**Ainda falta o fluxo de uma mesma história de texto através de várias áreas
e páginas.** O adaptador inicial usa caixas TextKit 2 independentes, com scroll
interno para transbordamento. Não afirmar que já é paginação automática de
Word. A próxima implementação deve conectar fragmentos à mesma história de
texto, medir alturas e invalidar somente áreas afetadas ao mover obstáculos.
Textos editados no adaptador inicial materializam atributos resolvidos nos
runs; refinar a preservação dos vínculos com estilos herdados é parte do
trabalho restante antes de oferecer estilos nomeados globais.

## Dimensões e transformações

A unidade interna é o ponto, 1/72 de polegada. A4 é 210 × 297 mm.
`px` usa uma convenção explícita de documento, inicialmente 96 px/in, sem
confundir pixels de exportação com pixels físicos da tela Retina. A densidade
é metadado, independente do zoom. Mudar o zoom nunca altera o documento.
As opções cm/in/px convertem para pontos antes de salvar.

Redimensionar a página não escala nem apaga objetos automaticamente. Objetos
fora da área devem ser sinalizados e reposicionados ou a página ampliada.
O demo ainda não mostra essa sinalização e não tem paginação automática.
Redimensionar uma forma composta escala a geometria dos filhos em um lote.
Rotação de grupos com filhos e transformações aninhadas ainda precisam de
tratamento completo; rotação de imagem individual já tem representação própria.

Imagens conservam o arquivo original por hash; recortar armazena um retângulo
normalizado (x, y, largura, altura), aplicado antes da rotação. Recorte, giro e
redimensionamento são reversíveis pelo histórico. O menu numérico inicial deve
ser substituído/complementado por alças visuais de recorte e proporção travável.

## Reconhecimento de diagramas

O motor inicial compara traços com retângulos, elipses, losangos, triângulos e
linhas. Casos ambíguos mantêm a tinta. A caixa original define a proporção:
um retângulo largo não vira um quadrado. A inserção de uma forma e do seu bloco
de texto vazio é uma única operação de histórico.

Conexões reconhecidas guardam IDs de origem/destino e estilo próprio. Sua rota
é recalculada usando a posição atual dos nós; a linha não fica solta quando os
nós se movem. Durante drag, o protótipo atual confirma a geometria no fim do
gesto; atualização contínua da linha ainda precisa ser afinada no aparelho.

Os pontos originais são preservados no documento. O primeiro capturador usa
toques coalescidos do UIKit e não guarda pressão, inclinação ou o arquivo
PencilKit completo. O adaptador PencilKit final deverá guardar `PKDrawing`
como asset, preservar esses atributos e suportar reconhecimento multitraço,
agrupamento temporal, desfazer conversão e correção manual. O checkbox já
desliga o reconhecimento; desenhar continua funcionando.

## Equações

Decisão inicial explícita: equações polinomiais de **uma incógnita**, até
grau 2; o resolvedor retorna raízes reais, ausência de solução real ou identidade.
A análise de expressão suporta os termos em ambos os lados, `x²`/`x^2`, sinais,
coeficientes decimais e multiplicação coeficiente–x. Parênteses, frações
estruturadas, sistemas e grau superior são rejeitados com necessidade de
correção, sem inventar resultado. Suporte a raízes complexas pode ser acrescido.

O fluxo final será: agrupar traços → reconhecer números, variável, operadores,
expoente e igualdade → propor expressão editável → validar AST → calcular →
mostrar resultado ligado à expressão. Reconhecer apenas os dígitos não basta.
O resolvedor não usa um LLM e não executa texto como código.
Uma leitura pouco confiável exige correção; o original permanece disponível.

O toggle de resolução foi colocado **ligado inicialmente**, como decisão
provisória coerente com o recurso automático pedido; pode ser desligado.
Ele não habilita reconhecimento matemático que ainda não foi implementado.

## Teia

Uma Teia é um `CanvasDocument(kind: .web)`. Cada card é um bloco
`.noteReference(documentID:)`; a nota original não é copiada. O host resolve
nome, data de criação e prévia, que devem acompanhar a revisão da nota.
Uma nota ausente vira card indisponível, preservando a posição e conexões;
remover um card não exclui a nota. Não adicionar notas automaticamente sem a
escolha do usuário.

Há três conceitos separados:

1. Data original de criação, imutável pelos comandos do editor.
2. Sequência cronológica derivada, exibida inicialmente por setas discretas.
3. Posições e conexões manuais que o usuário pode reorganizar livremente.

Mover um card não falsifica a cronologia nem altera a nota. Texto, tinta,
formas e imagens adicionais usam o mesmo motor do canvas. Um card pode
participar de Teias diferentes. Ligações manuais e cronológicas são camadas
distintas, inclusive para futuras opções de ocultação.

Entradas finais: botão na nota aberta; botão na pasta; botão no card da nota.
Todas devem abrir o mesmo seletor para criar/escolher uma Teia e acrescentar
as notas selecionadas. O demo cria Teias diretamente e tem uma coleção geral;
**não implementa ainda pastas persistentes nem o seletor de Teias existentes**.
Prévia atual do demo é textual; a miniatura fiel do canvas deve usar cache
por `(documentID, revision, size)` no pipeline de derivados.

## Sequência restante da etapa 2

1. Compilar `GotItCanvasUI` e `GotItDemo` no Xcode e corrigir qualquer erro de
   SDK; executar cenários de edição, teclado, Pencil e multitouch no iPad.
2. Concluir seleção e alças de tamanho/recorte, clipping de conteúdo dentro
   das formas, estilos nomeados, tabelas simples e fluxo textual entre áreas.
3. Integrar PencilKit e reconhecimento multitraço; testar equações manuscritas
   com corpus real, correção de baixa confiança e preservação do original.
4. Concluir pastas, seleção de Teias existentes, miniaturas fiéis e navegação.
5. Virtualizar a criação/reciclagem de views, e não apenas ocultá-las fora da
   viewport; medir documentos grandes e substituir gravações integrais por
   deltas antes de uma experiência de digitação de produção.

O adaptador atual oculta views fora da área visível, mas ainda as instancia.
Não se trata de virtualização completa nem de memória proporcional apenas
ao que está na tela. Essas limitações são critérios abertos de conclusão.

## Fontes técnicas consultadas

- [TextKit: exclusões](https://developer.apple.com/documentation/uikit/nstextcontainer/exclusionpaths)
- [Parágrafos e listas](https://developer.apple.com/documentation/uikit/nsmutableparagraphstyle)
- [PencilKit: PKDrawing](https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct)
- [Vision: reconhecimento textual](https://developer.apple.com/documentation/vision/recognizetextrequest)
- [XcodeGen: pacotes locais](https://yonaskolb.github.io/XcodeGen/Docs/Usage.html)

Texto/OCR disponível em uma API não implica reconhecimento confiável de
notação matemática. Recursos de SDK recentes devem ser verificados por
disponibilidade e aparelho antes de fixar a versão mínima do produto.
