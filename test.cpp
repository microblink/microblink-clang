#include <variant>
#include <cstdint>
#include <stdexcept>

enum struct Foo : std::uint8_t
{
    First = 0,
    Second
};

enum struct Bar : std::uint8_t
{
    First = 0,
    Second
};

using S = std::variant< Foo, Bar >;

static_assert( sizeof( S ) == 2 );

int check( S const & bla )
{
    if ( std::holds_alternative< Bar >( bla ) )
    {
        throw std::invalid_argument( "wrong alternative!" );
    }
    return 0;
}

int main()
{
    S bla = Foo::First;
    return check( bla );
}
