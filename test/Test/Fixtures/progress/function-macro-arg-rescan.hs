#define ID(x) x
#define TWICE(x) ID(x) + ID(x)
#define SUM(a,b) (a + b)
c = ID(ID(7))
d = TWICE(SUM(1, 2))
