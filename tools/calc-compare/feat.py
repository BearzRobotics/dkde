C = []
def add(cat, expr, **ov): C.append((cat, expr, ov))
# symbolic / exact
add("exact", "sqrt(8)"); add("exact", "sqrt(2)^2"); add("exact", "sin(pi/6)"); add("exact", "cos(pi/3)"); add("exact", "sqrt(2)*sqrt(3)")
add("exact", "e^(ln(5))"); add("exact", "ln(e^2)"); add("exact", "pi/4*4"); add("exact", "2/3 + 3/4"); add("exact", "sqrt(1/4)")
# algebra
add("algebra", "expand((x+1)^3)"); add("algebra", "factor(x^2-1)"); add("algebra", "simplify(2x+3x)"); add("algebra", "2x+3x")
add("algebra", "solve(x^2=4, x)", qalc="solve(x^2=4, x)"); add("algebra", "x^2-5x+6=0"); add("algebra", "diff(x^3, x)", qalc="diff(x^3, x)")
add("algebra", "integrate(x^2, x)", qalc="integrate(x^2, x)", ours="integral(x^2, x)")
add("algebra", "x+y=5; x-y=1", qalc="x+y=5; x-y=1", insect=None, kalker=None)
# logic / bases / rounding
add("logic", "5 > 3", insect="5 > 3"); add("logic", "0.1+0.2 == 0.3", ours="0.1+0.2 = 0.3")
add("bases", "0xFF + 1"); add("bases", "255 to hex", insect="255 to hex", kalker="255 to hex"); add("bases", "0b1010 + 1")
add("rounding", "round(2.567, 2)", insect="round(2.567, 2)"); add("rounding", "round(1234.5678, -2)"); add("rounding", "trunc(-2.7)"); add("rounding", "int(7/2)")
add("rounding", "ceil(5/2)")
# vectors / matrices
add("vector", "dot([1,2,3],[4,5,6])"); add("vector", "cross([1,0,0],[0,1,0])"); add("vector", "norm([3,4])", qalc="abs([3,4])")
add("vector", "rref([1,2,3;4,5,6])", insect=None, kalker=None); add("vector", "rank([1,2;2,4])", qalc="rank([1,2;2,4])", insect=None, kalker=None)
# complex extras
add("complex", "arg(1+i)"); add("complex", "abs(i)"); add("complex", "re(3+4i)"); add("complex", "im(3+4i)")
# user functions / variables
add("user", "f(x)=x^2; f(3)", qalc="f(x)=x^2; f(3)", insect=None, kalker=None)
add("user", "x=5; x*2", qalc="x=5; x*2", insect="x=5; x*2", kalker=None)
# number theory
add("number", "factor(360)", qalc="factorize(360)", insect=None, kalker=None); add("number", "7!!", qalc="7!!", insect=None, kalker=None)
add("number", "5! + 3!"); add("number", "primepi(100)", insect=None, kalker=None); add("number", "nextprime(100)", insect=None, kalker=None)
# percent forms
add("percent", "20% of 50", insect="20% of 50", kalker=None); add("percent", "10% of 200", insect="10% of 200", kalker=None)
add("percent", "100 - 20%", insect="100 - 20%", kalker=None); add("percent", "50 to percent", ours="0.5 to percent", qalc="0.5 to percent", insect=None, kalker=None)
# time / duration
add("time", "1 hour + 30 min", kalker=None); add("time", "5 days to hours", insect="5 days to hours", kalker=None); add("time", "1 week to days", insect="1 week to days", kalker=None)
add("time", "90 min to h", insect="90 min to h", kalker=None)
# series / stats
add("series", "sum(1/k^2, k, 1, 100)", qalc="sum(1/k^2, k, 1, 100)", insect=None, kalker="sum(k=1,100,1/k^2)")
add("series", "prod(k, k, 1, 10)", qalc="product(k, 1, 10, k)", insect=None, kalker=None)
add("stats", "percentile(50, 1,2,3,4,5)", insect=None, kalker=None); add("stats", "mode(1,2,2,3)", insect=None, kalker=None)
add("stats", "geomean(1,2,4,8)", insect=None, kalker=None)
# notation
add("notation", "2pi"); add("notation", "(1+2)(3+4)"); add("notation", "3 4"); add("notation", "1,5+2,5", ours="1.5+2.5"); add("notation", "5 mod 3", insect=None, kalker="5 % 3", qalc="5 mod 3")
add("notation", "10^3!"); add("notation", "1.5e3 m to km", kalker=None); add("notation", "√16"); add("notation", "π"); add("notation", "2²")
