# Notified Body registers

This repository contains code to copy the European Commission's
[New Approach Notified and Designated Organisations (NANDO)](http://ec.europa.eu/growth/tools-databases/nando/)
database into a machine-readable form using the [Open Register specification](https://github.com/openregister/specification).
The code will output Registers Seialisation Format (RSF) files
that can be loaded into any compatible Register implementaion.

The data collected is [copyright European Union, 1995-2018](https://ec.europa.eu/info/legal-notice_en#copyright-notice).

## Running

Assuming you have an up-to-date installation of Ruby.

```
$ bundle install
$ bundle exec rake
```

If you have an installation of [orc](https://github.com/register-dynamics/orc),
you can also build a database of the entire collection of Registers.

```
$ bundle exec rake nando.catalogue.sqlite
```

## Caveats

1. At the moment the scraper and data model do not include Construction products
   as defined by Regulation (EU) No 305/2011.
2. Two or three bodies reference products that don't exist in the main database,
   and these entries are skipped. A warning will be printed when this occurs.

## License

[MIT License](./LICENSE)