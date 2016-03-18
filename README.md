Preliminary note for Windows users
==================================

The build instructions for `gprbuild` may have a slight UNIX flavor but they can
be used on Windows platforms with a full Cygwin installation. The latter makes
it simpler to build `gprbuild` but is not required to use it.

Configuring
===========

Configuring is usually done simply as:

    $ ./configure

Two parameters may be worth specifying: `--prefix` for specifying the
installation root and `--build` for specifying the build host.

In particular, on Windows, when using cygwin to build, it is necessary to
configure with `--build=i686-pc-mingw32` if one wants to use 32 bit mingw based
compilers such as GNAT Pro or GNAT GPL, and with `--build=x86_64-pc-mingw32` for
64 bit compilers. Here are examples of such commands:

    $ ./configure --build=i686-pc-mingw32 --prefix=$HOME/local

    $ ./configure --build=x86_64-pc-mingw32 --prefix=$HOME/local

Using alternate GNAT Sources
============================

Gprbuild uses some sources of the GNAT package. They are expected by default to
be located in the `gnat/` subdirectory of Gprbuild. Only some of the GNAT
sources are required, but note that having all of the GNAT sources present in
the `gnat/` subdirectory will result in build failure.

In order to use GNAT sources from another location, create a link named
`gnat_src` and call the Makefile target `copy_gnat_src`:

    $ ln -s <path_to_gnat_sources> gnat_src
    $ make copy_gnat_src

That will place links into the `gnat/` subdirectory for each of the required
GNAT source files.

On Windows with Cygwin, the files must be copied because symbolic links do not
work. The definition of `GNAT_SOURCE_DIR` in the Makefile needs to be modified
so that it specifies the path to the GNAT sources. For example:

    GNAT_SOURCE_DIR=$(HOME)/gnat

Then call the Makefile target `copy_gnat_src`:

    $ make copy_gnat_src

The Makefile will recognize the use of Windows and will therefore place a copy
of the required files into the `gnat/` subdirectory.

Alternatively you can specify `GNAT_SOURCE_DIR` on the command line when
invoking the makefile target:

    $ make copy_gnat_src GNAT_SOURCE_DIR=<path/to/gnat/sources>

Note that target `copy_gnat_src` is invoked automatically by target `complete`.

Building and Installing
=======================

XML/Ada must be installed before building.

Building the main executables is done simply with:

    $ make all

When compiling, you can choose whether you want to link statically with XML/Ada
(the default), or dynamically. To compile dynamically, you should run:

    $ make LIBRARY_TYPE=relocatable all

instead of the above.

Installation is done with:

    $ make install

Doc & Examples
==============

The documentation is provided in various formats in the doc subdirectory.

It refers to concrete examples that are to be found in the examples
subdirectory. Each example can be built easily using the simple attached
Makefile:

    $ make all    # build the example
    $ make run    # run the executable(s)
    $ make clean  # cleanup

All the examples can be `built/run/cleaned` using the same targets and the top
level examples Makefile.
