# Got It! — demonstração nativa da etapa 2

Código para iPhone/iPad (iOS 18+), com SwiftUI + UIKit/TextKit 2.
**Ainda não compilado nem executado em ambiente Apple nesta entrega.**
O teste Linux do pacote exclui o código UIKit; não substitui esta verificação.

No Mac, com Xcode e [XcodeGen](https://github.com/yonaskolb/XcodeGen) instalados:

```sh
cd Examples/GotItDemo
xcodegen generate
open GotItDemo.xcodeproj
```

Selecione o scheme `GotItDemo` e um simulador iPhone/iPad. Para aparelho físico,
configure seu time de assinatura no Xcode. O bundle identifier é provisório.

O demo fornece notas, SQLite, canvas A4/customizado, menu de objetos, desenho
com reconhecimento geométrico, importação simples de imagem, Teias e cálculo
de equação digitada. Clique no espaço vazio para criar texto; toque prolongado
ou clique secundário abre o menu. Arraste objetos para mover. Os menus de
objeto incluem tamanho, cores, contorno, recorte e rotação. Use dois dedos para
zoom; escolha Desenhar no menu para capturar tinta.

Os detalhes, requisitos ainda abertos e limites estão em
[stage-2-canvas.md](../../docs/stage-2-canvas.md). Em especial, não há ainda
OCR de equações integrado, pastas persistentes, virtualização completa ou
editor Word completo. As prévias das notas no demo são textuais.

Os arquivos de imagem importados ficam na área privada de Application Support.
Ainda faltam compressão, coleta segura de assets e políticas de backup da etapa 3.
Este é um protótipo técnico; não usar como único repositório de notas reais.
