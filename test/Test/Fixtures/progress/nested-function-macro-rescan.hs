#define WRAP(x) (x)
#define INNER WRAP(1)
#define OUTER WRAP(INNER)
a = INNER
b = OUTER
