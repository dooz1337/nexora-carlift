-- carlift: placed car lifts. Import once; idempotent.
CREATE TABLE IF NOT EXISTS `car_lifts` (
    `id`         INT          NOT NULL AUTO_INCREMENT,
    `x`          DOUBLE       NOT NULL,
    `y`          DOUBLE       NOT NULL,
    `z`          DOUBLE       NOT NULL,
    `heading`    FLOAT        NOT NULL DEFAULT 0,
    `prop`       VARCHAR(64)  NOT NULL,
    `max_height` FLOAT        NOT NULL DEFAULT 2.5,
    `created_by` VARCHAR(80)  NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
