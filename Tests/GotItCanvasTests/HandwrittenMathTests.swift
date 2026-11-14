import Testing
@testable import GotItCanvas

@Test func readFormulasAreCleanedUp() {
    #expect(HandwrittenMath.normalize("12 + 7 =") == "12+7=")
    #expect(HandwrittenMath.normalize("3 × 4 − 2 =") == "3*4-2=")
    #expect(HandwrittenMath.normalize("1O + 5 =") == "10+5=", "O read for zero between digits")
    #expect(HandwrittenMath.normalize("x2 - 5x + 6 = 0") == "x^2-5x+6=0", "the small 2 of x² read on the line")
    #expect(HandwrittenMath.normalize("2X + 4 = 10") == "2x+4=10")
    #expect(HandwrittenMath.normalize("Reunião às 10h = amanhã") == nil, "writing is not math")
    #expect(HandwrittenMath.normalize("1 + 1") == nil, "no equals sign")
    #expect(HandwrittenMath.normalize("1 = 2 = 3") == nil)
}

@Test func formulasAreAnswered() {
    #expect(HandwrittenMath.answer("12+7=") == "19")
    #expect(HandwrittenMath.answer("3*4-2=") == "10")
    #expect(HandwrittenMath.answer("(2+3)*4=") == "20")
    #expect(HandwrittenMath.answer("2^10=") == "1024")
    #expect(HandwrittenMath.answer("10/4=") == "2,5")
    #expect(HandwrittenMath.answer("1/3=") == "0,3333")
    #expect(HandwrittenMath.answer("5-8=") == "−3")
    #expect(HandwrittenMath.answer("1/0=") == nil)
    #expect(HandwrittenMath.answer("2x+4=10") == "x = 3")
    #expect(HandwrittenMath.answer("x^2-5x+6=0") == "x = 2 ou x = 3")
    #expect(HandwrittenMath.answer("x^2+1=0") == "sem solução real")
    #expect(HandwrittenMath.answer("x^3=8") == nil, "degree above 2")
    #expect(HandwrittenMath.answer("12+=") == nil)
}
