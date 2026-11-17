# Aplicativo Got It!

Alvo iPhone/iPad e Mac Catalyst. Configure XcodeGen e abra o scheme GotItApp.
A versão desta revisão ainda aguarda validação Apple; veja [critérios](../../docs/stage-2-review.md).

# Got It! — demonstração nativa da etapa 2

Código para iPhone/iPad (iOS 18+), com SwiftUI, UIKit/TextKit 2 e PencilKit.
O CI compila com SDK Apple e executa testes nativos/UI; consulte o resultado
do commit atual. Testes Linux, isoladamente, não validam a interface.

No Mac, com Xcode e [XcodeGen](https://github.com/yonaskolb/XcodeGen) instalados:

```sh
cd Apps/GotIt
xcodegen generate
open GotItApp.xcodeproj
```

Selecione o scheme `GotItApp` e um simulador iPhone/iPad. Para aparelho físico,
configure seu time de assinatura no Xcode. O bundle identifier é provisório.

O demo fornece notas, SQLite, canvas A4/customizado, menu de objetos, desenho
com reconhecimento geométrico, importação simples de imagem, Teias e cálculo
de equação digitada. Clique no espaço vazio para criar texto; toque prolongado
ou clique secundário abre o menu. Arraste objetos para mover. Os menus de
objeto incluem tamanho, cores, contorno, recorte e rotação. Use dois dedos para
zoom. Selecione uma caneta na paleta para começar a desenhar; nesse modo,
use dois dedos para deslocar o canvas. Páginas ficam à esquerda no iPad e
em um painel no iPhone. A barra superior formata o texto em edição.

Os detalhes, requisitos ainda abertos e limites estão em
[stage-2-canvas.md](../../docs/stage-2-canvas.md). Em especial, não há ainda
OCR de equações integrado, pastas persistentes, virtualização completa ou
editor Word completo. Leia [native-editor.md](../../docs/native-editor.md)
para páginas, ferramentas, persistência de desenhos e limites de PDF/stickers.

Os arquivos de imagem importados ficam na área privada de Application Support.
Ainda faltam compressão, coleta segura de assets e políticas de backup da etapa 3.
Este é um protótipo técnico; não usar como único repositório de notas reais.
