-- public schema for database interface
create schema albion
;

-- UTILITY FUNCTIONS

create or replace function albion.snap_distance()
returns real
language plpgsql immutable
as
$$
    begin
        return (select snap_distance from _albion.metadata);
    end;
$$
;

create or replace function albion.precision()
returns real
language plpgsql stable
as
$$
    begin
        return (select precision from _albion.metadata);
    end;
$$
;


create or replace function albion.current_section_id()
returns varchar
language plpgsql stable
as
$$
    begin
        return (select current_section from _albion.metadata);
    end;
$$
;

create or replace function albion.current_section_geom()
returns geometry
language plpgsql stable
as
$$
    begin
        return (select geom from _albion.grid where id=albion.current_section_id());
    end;
$$
;


create or replace function albion.update_hole_geom()
returns boolean
language plpgsql
as
$$
    begin
        with dz as (
            select 
                hole_id, 
                from_ as md2, coalesce(lag(from_) over w, 0) as md1,
                (deep + 90)*pi()/180 as wd2,  coalesce(lag((deep+90)*pi()/180) over w, 0) as wd1,
                azimuth*pi()/180 as haz2,  coalesce(lag(azimuth*pi()/180) over w, 0) as haz1
            from _albion.deviation 
            where azimuth >= 0 and azimuth <=360 and deep < 0 and deep > -180
            window w AS (partition by hole_id order by from_)
        ),
        pt as (
            select dz.hole_id, md2, wd2, haz2, 
            st_x(c.geom) + sum(0.5 * (md2 - md1) * (sin(wd1) * sin(haz1) + sin(wd2) * sin(haz2))) over w as x,
            st_y(c.geom) + sum(0.5 * (md2 - md1) * (sin(wd1) * cos(haz1) + sin(wd2) * cos(haz2))) over w as y,
            st_z(c.geom) - sum(0.5 * (md2 - md1) * (cos(wd2) + cos(wd1))) over w as z
            from dz join _albion.hole as h on h.id=hole_id join _albion.collar as c on c.id=h.collar_id
            window w AS (partition by hole_id order by md1)
        ),
        line as (
            select hole_id, st_makeline(('SRID={srid}; POINTZ('||x||' '||y||' '||z||')')::geometry order by md2 asc) as geom
            from pt
            group by hole_id
        )
        update _albion.hole as h set geom=(select st_addpoint(geom, (
                select c.geom from _albion.hole as hh join _albion.collar as c on c.id=hh.collar_id
                where hh.id=h.id), 0)
            from line as l where l.hole_id=h.id);
        return 't'::boolean;
    end;
$$
;

create or replace function albion.hole_piece(from_ real, to_ real, hole_id varchar)
returns geometry
language plpgsql stable
as
$$
    declare
        len real;
        hole_geom geometry;
        collar_id varchar;
    begin
        if to_ <= from_ then
            return (select null);
        end if;

        select st_3dlength(h.geom), h.geom, h.collar_id into len, hole_geom, collar_id
        from _albion.hole as h
        where h.id = hole_id;

        if len > 0 and from_/len < 1 and to_/len < 1 then
            return (
            select st_makeline(st_3dlineinterpolatepoint(hole_geom, from_/st_3dlength(hole_geom)),
                               st_3dlineinterpolatepoint(hole_geom, to_/st_3dlength(hole_geom))));

        elsif len > 0  and from_/len < 1 then
            -- extrapolate last point from last segment
            return (
            with last_segment as (
                select st_pointn(hole_geom, st_numpoints(hole_geom)-1) as start_, st_endpoint(hole_geom) as end_
            ),
            direction as (
                select 
                (st_x(end_) - st_x(start_))/st_3ddistance(end_, start_) as x, 
                (st_y(end_) - st_y(start_))/st_3ddistance(end_, start_) as y, 
                (st_z(end_) - st_z(start_))/st_3ddistance(end_, start_) as z 
                from last_segment
            )
            select st_makeline(
                st_3dlineinterpolatepoint(hole_geom, from_/st_3dlength(hole_geom)),
                    st_setsrid(st_makepoint(
                        st_x(s.end_) + (to_-len)*d.x,
                        st_y(s.end_) + (to_-len)*d.y,
                        st_z(s.end_) + (to_-len)*d.z
                    ), st_srid(hole_geom)))
            from direction as d, last_segment as s
            );
        elsif len > 0  then
            -- extrapolate last point from last segment
            return (
            with last_segment as (
                select st_pointn(hole_geom, st_numpoints(hole_geom)-1) as start_, st_endpoint(hole_geom) as end_
            ),
            direction as (
                select 
                (st_x(end_) - st_x(start_))/st_3ddistance(end_, start_) as x, 
                (st_y(end_) - st_y(start_))/st_3ddistance(end_, start_) as y, 
                (st_z(end_) - st_z(start_))/st_3ddistance(end_, start_) as z
                from last_segment
            )
            select st_setsrid(st_makeline(
                    st_makepoint(
                        st_x(s.end_) + (from_-len)*d.x,
                        st_y(s.end_) + (from_-len)*d.y,
                        st_z(s.end_) + (from_-len)*d.z
                    ),
                    st_makepoint(
                        st_x(s.end_) + (to_-len)*d.x,
                        st_y(s.end_) + (to_-len)*d.y,
                        st_z(s.end_) + (to_-len)*d.z
                    )), st_srid(hole_geom))
            from direction as d, last_segment as s
            );
        else
            -- vertical hole
            return (
            select st_setsrid(st_makeline(
                    st_makepoint(st_x(geom), st_y(geom), st_z(geom) - from_),
                    st_makepoint(st_x(geom), st_y(geom), st_z(geom) - to_)), st_srid(hole_geom))
            from _albion.collar where id=collar_id
            );
        end if;

    end;
$$
;

-- 2D projected geometry from 3D geometry
create or replace function albion.to_section(geom_ geometry, section geometry)
returns geometry
language plpgsql immutable
as
$$
    begin
        if st_geometrytype(geom_) = 'ST_LineString' then
            return (
                with point as (
                    select (t.d).path as p, (t.d).geom as geom from (select st_dumppoints(geom_) as d) as t 
                )
                select st_setsrid(st_makeline(('POINT('||st_linelocatepoint(section, p.geom)*st_length(section)||' '||st_z(p.geom)||')')::geometry order by p), st_srid(geom_))
                from point as p
            );
        elsif st_geometrytype(geom_) = 'ST_Point' then
            return (
                select st_setsrid(('POINT('||st_linelocatepoint(section, geom_)*st_length(section)||' '||st_z(geom_)||')')::geometry, st_srid(geom_))
            );
        else
            return null;
        end if;
    end;
$$
;

-- 3D geometry from 2D projected geometry
create or replace function albion.from_section(linestring geometry, section geometry)
returns geometry
language plpgsql immutable
as
$$
    begin
        return (
            with point as (
                select (t.d).path as p, st_lineinterpolatepoint(section, st_x((t.d).geom)/st_length(section)) as geom, st_y((t.d).geom) as z 
                from (select st_dumppoints(linestring) as d) as t 
            )
            select st_setsrid(
                st_makeline(('POINT('||st_x(p.geom) ||' '||st_y(p.geom)||' '||p.z||')')::geometry order by p),
                st_srid(linestring))
            from point as p
        );
    end;
$$
;

-- UTILITY VIEWS

create or replace view albion.close_point as
with ends as (
    select id, st_startpoint(geom) as geom from _albion.grid
    union
    select id, st_endpoint(geom) as geom from _albion.grid
)
select row_number() over() as id, e.geom::geometry('POINT', {srid}) 
from ends as e
where exists (
    select 1 
    from _albion.grid as g 
    where st_dwithin(e.geom, g.geom, 2*(select snap_distance from _albion.metadata)) 
    and not st_intersects(e.geom, g.geom))
;

create materialized view albion.small_edge as
with all_points as (
    select distinct (st_dumppoints(geom)).geom as geom from _albion.grid
)
select row_number() over() as id, a.geom::geometry('POINT', {srid}) 
from all_points as a, all_points as b
where st_dwithin(a.geom, b.geom, 2*albion.snap_distance())
and not st_intersects(a.geom, b.geom)
;


create materialized view albion.cell
as
with collec as (
    select
            (st_dump(
                coalesce(
                    st_split(
                        a.geom,
                        (select st_collect(geom)
                            from _albion.grid as b
                            where a.id!=b.id and st_intersects(a.geom, b.geom)
                            and st_dimension(st_intersection(a.geom, b.geom))=0)),
                    a.geom)
        )).geom as geom
    from _albion.grid as a
),
poly as (
    select (st_dump(st_polygonize(geom))).geom as geom from collec
)
select row_number() over() as id, geom::geometry('POLYGON', {srid}) from poly where geom is not null
;


create view albion.intersection_without_hole as
with point as (
    select (st_dumppoints(geom)).geom as geom from _albion.grid
),
no_hole as (
    select geom from point
    except
    select st_force2d(st_startpoint(geom)) from _albion.hole
)
select row_number() over() as id, geom::geometry('POINT', {srid}) from no_hole
;


-- DATABASE INTERFACE (UPDATABE VIEWS)

create or replace view albion.grid as
select id, geom, st_azimuth(st_startpoint(geom), st_endpoint(geom)) as azimuth
from _albion.grid
;

create or replace function albion.grid_instead_fct()
returns trigger
language plpgsql
as
$$
    begin
        -- snap geom to collars (adds points to geom)
        if tg_op = 'INSERT' or tg_op = 'UPDATE' then
            select st_removerepeatedpoints(new.geom, albion.snap_distance()) into new.geom;

            with snap as (
                select st_collect(geom) as geom
                from (
                    select st_force2D(geom) as geom
                    from  _albion.collar
                    where st_dwithin(geom, new.geom, albion.snap_distance())
                    union all
                    select st_closestpoint(geom, new.geom) as geom
                    from _albion.grid as g
                    where st_dwithin(geom, new.geom, albion.snap_distance())
                    and st_distance(st_closestpoint(g.geom, new.geom), (select c.geom from _albion.collar as c order by c.geom <-> st_closestpoint(g.geom, new.geom) limit 1)) > albion.snap_distance()
                ) as t
            )
            select coalesce(st_snap(new.geom, (select geom from snap), albion.snap_distance()), new.geom) into new.geom; 

            with new_points as (
                select st_collect(geom) as geom from (select (st_dumppoints(new.geom)).geom as geom) as t
            ),
            nearby as (
                select id from _albion.grid
                where st_dwithin(geom, new.geom, albion.snap_distance())
            )
            update _albion.grid as g set geom = st_snap(g.geom, (select geom from new_points), albion.snap_distance())
            where id in (select id from nearby);
        end if;

        if tg_op = 'INSERT' then
            insert into _albion.grid(geom) values(new.geom) returning id into new.id;
        elsif tg_op = 'UPDATE' then
            update _albion.grid set geom=new.geom where id=new.id;
        elsif tg_op = 'DELETE' then
            delete from _albion.grid where id=old.id;
        end if;

        if tg_op = 'INSERT' or tg_op = 'UPDATE' then
            return new;
        elsif tg_op = 'DELETE' then
            return old;
        end if;
    end;
$$
;

create trigger grid_instead_trig
    instead of insert or update or delete on albion.grid
       for each row execute procedure albion.grid_instead_fct()
;

create view albion.collar as select id, geom, comments from _albion.collar
;

create view albion.metadata as select id, srid, current_section, snap_distance, origin, precision from _albion.metadata
;

create view albion.hole as select id, collar_id, geom, st_3dlength(geom) as len from _albion.hole
;

create view albion.deviation as select hole_id, from_, deep, azimuth from _albion.deviation
;

create view albion.formation as select id, hole_id, from_, to_, code, comments, geom from _albion.formation
;

create or replace function albion.formation_instead_fct()
returns trigger
language plpgsql
as
$$
    begin
        if tg_op = 'INSERT' or tg_op = 'UPDATE' then
            select albion.hole_piece(new.from_, new.to_, new.hole_id) into new.geom;
        end if;
            
        if tg_op = 'INSERT' then
            insert into _albion.formation(id, hole_id, from_, to_, code, comments, geom) values(new.id, new.hole_id, new.from_, new.to_, new.code, new.comments, new.geom);
            return new;
        elsif tg_op = 'UPDATE' then
            update _albion.formation set hole_id=new.hole_id, from_=new.from_, to_=new.to_, code=new.code, comments=new.comments, geom=new.geom where id=new.id;
            return new;
        elsif tg_op = 'DELETE' then
            delete from _albion.formation where id=old.id;
            return old;
        end if;
    end;
$$
;

create trigger formation_instead_trig
    instead of insert or update or delete on albion.formation
       for each row execute procedure albion.formation_instead_fct()
;


create view albion.resistivity as select id, hole_id, from_, to_, rho, geom from _albion.resistivity
;

create or replace function albion.resistivity_instead_fct()
returns trigger
language plpgsql
as
$$
    begin
        if tg_op = 'INSERT' or tg_op = 'UPDATE' then
            select albion.hole_piece(new.from_, new.to_, new.hole_id) into new.geom;
        end if;
            
        if tg_op = 'INSERT' then
            insert into _albion.resistivity(id, hole_id, from_, to_, rho, geom) values(new.id, new.hole_id, new.from_, new.to_, new.rho, new.geom);
            return new;
        elsif tg_op = 'UPDATE' then
            update _albion.resistivity set hole_id=new.hole_id, from_=new.from_, to_=new.to_, rho=new.rho, geom=new.geom where id=new.id;
            return new;
        elsif tg_op = 'DELETE' then
            delete from _albion.resistivity where id=old.id;
            return old;
        end if;
    end;
$$
;

create trigger resistivity_instead_trig
    instead of insert or update or delete on albion.resistivity
       for each row execute procedure albion.resistivity_instead_fct()
;


create view albion.radiometry as select id, hole_id, from_, to_, gamma, geom from _albion.radiometry
;

create view albion.lithology as select id, hole_id, from_, to_, code, comments, geom from _albion.lithology
;

create view albion.mineralization as select id, hole_id, from_, to_, oc, accu, grade, geom from _albion.mineralization
;

create or replace view albion.formation_section as
select f.id, f.hole_id, f.from_, f.to_, f.code, f.comments, albion.to_section(f.geom, g.geom)::geometry('LINESTRING', {srid}) as geom
from albion.formation as f 
join albion.hole as h on h.id=f.hole_id
join albion.grid as g on st_intersects(st_startpoint(h.geom), g.geom)
where g.id = albion.current_section_id()
;

create or replace view albion.resistivity_section as
select f.id, f.hole_id, f.from_, f.to_, f.rho, albion.to_section(f.geom, g.geom)::geometry('LINESTRING', {srid}) as geom
from albion.resistivity as f 
join albion.hole as h on h.id=f.hole_id
join albion.grid as g on st_intersects(st_startpoint(h.geom), g.geom)
where g.id = albion.current_section_id()
;

create or replace view albion.radiometry_section as
select f.id, f.hole_id, f.from_, f.to_, f.gamma, albion.to_section(f.geom, g.geom)::geometry('LINESTRING', {srid}) as geom
from albion.radiometry as f 
join albion.hole as h on h.id=f.hole_id
join albion.grid as g on st_intersects(st_startpoint(h.geom), g.geom)
where g.id = albion.current_section_id()
;


create or replace view albion.collar_section as
select f.id, f.comments, albion.to_section(f.geom, g.geom)
from albion.collar as f 
join albion.grid as g on st_intersects(f.geom, g.geom)
where g.id = albion.current_section_id()
;

-- create graph edges for the specified grid element
create or replace function albion.auto_connect(name varchar, grid_id varchar)
returns boolean
language plpgsql
as
$$
    begin
        execute (select replace(replace('
        with node as ( 
            select f.id, f.hole_id, st_3dlineinterpolatepoint(f.geom, .5) as geom
            from albion.$name_node as f 
            join albion.hole as h on h.id=f.hole_id
            join albion.grid as g on st_intersects(st_startpoint(h.geom), g.geom)
            where g.id = ''$grid_id''
        ),
        hole_pair as (
            select
                row_number() over() as id,
                h.id as right, 
                lag(h.id) over (order by st_linelocatepoint((select geom from albion.grid where id=''$grid_id''), st_startpoint(h.geom))) as left
            from (select distinct hole_id from node) as n
            join albion.hole as h on h.id=n.hole_id
        ),
        possible_edge as (
            select 
                n1.id as start_, 
                n2.id as end_,
                st_makeline(n1.geom, n2.geom) as geom, 
                abs(st_z(n2.geom) - st_z(n1.geom))/st_distance(n2.geom, n1.geom) angle,
                count(1) over (partition by n1.id) as c1,  
                count(1) over (partition by n2.id) as c2, 
                rank() over (partition by p.id order by abs(st_z(n2.geom) - st_z(n1.geom))/st_distance(n2.geom, n1.geom)) as rk
            from hole_pair as p
            join node as n1 on n1.hole_id=p.left
            join node as n2 on n2.hole_id=p.right
        )
        insert into albion.$name_edge(start_, end_, grid_id, geom)
        select e.start_, e.end_, ''$grid_id'', e.geom from possible_edge as e
        where e.rk <= greatest(e.c1, e.c2)
        and not exists (select 1 from albion.$name_edge where (start_=e.start_ and end_=e.end_) or (start_=e.end_ and end_=e.start_))
        ', '$name', name), '$grid_id', grid_id::varchar)); 
        return 't'::boolean;

    end;
$$
;

create or replace function albion.auto_ceil_and_wall(name varchar, grid_id varchar)
returns boolean
language plpgsql
as
$$
    begin
        execute (select replace(replace('
            insert into _albion.$name_wall_edge(id, grid_id, geom)
            select e.id, e.grid_id, albion.$name_snap_edge_to_grid(st_makeline(
                st_3dlineinterpolatepoint(n1.geom, coalesce(
                     (select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n2.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=n1.id and end_=o.id) 
                        and st_z(st_3dlineinterpolatepoint(o.geom, .5)) >= st_z(st_3dlineinterpolatepoint(n2.geom, .5)))
                    /(select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n2.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=n1.id and end_=o.id))
                , 1)), 
                st_3dlineinterpolatepoint(n2.geom, coalesce(
                     (select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n1.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=o.id and end_=n2.id) 
                        and st_z(st_3dlineinterpolatepoint(o.geom, .5)) >= st_z(st_3dlineinterpolatepoint(n1.geom, .5))) 
                    /(select sum(st_3dlength(o.geom)) from albion.$name_node as o
                        where o.hole_id=n1.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=o.id and end_=n2.id))
                , 1)) 
            ), e.start_, e.end_, ''$grid_id'') as geom
            from albion.$name_edge as e
            join albion.$name_node as n1 on n1.id=e.start_
            join albion.$name_node as n2 on n2.id=e.end_
            where e.grid_id=''$grid_id''
            and not exists (select 1 from albion.$name_wall_edge where id=e.id)

        ', '$name', name), '$grid_id', grid_id::varchar)); 

        execute (select replace(replace('
            insert into _albion.$name_ceil_edge(id, grid_id, geom)
            select e.id, e.grid_id, albion.$name_snap_edge_to_grid(st_makeline(
                st_3dlineinterpolatepoint(n1.geom, coalesce(
                     (select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n2.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=n1.id and end_=o.id) 
                        and st_z(st_3dlineinterpolatepoint(o.geom, .5)) > st_z(st_3dlineinterpolatepoint(n2.geom, .5)))
                    /(select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n2.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=n1.id and end_=o.id))
                , 0)), 
                st_3dlineinterpolatepoint(n2.geom, coalesce(
                     (select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n1.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=o.id and end_=n2.id) 
                        and st_z(st_3dlineinterpolatepoint(o.geom, .5)) > st_z(st_3dlineinterpolatepoint(n1.geom, .5))) 
                    /(select sum(st_3dlength(o.geom)) from albion.$name_node as o 
                        where o.hole_id=n1.hole_id 
                        and exists (select 1 from albion.$name_edge where start_=o.id and end_=n2.id))
                , 0)) 
            ), e.start_, e.end_, ''$grid_id'') as geom
            from albion.$name_edge as e
            join albion.$name_node as n1 on n1.id=e.start_
            join albion.$name_node as n2 on n2.id=e.end_
            where e.grid_id=''$grid_id''
            and not exists (select 1 from albion.$name_ceil_edge where id=e.id)
        ', '$name', name), '$grid_id', grid_id::varchar)); 

        return 't'::boolean;
    end;
$$
;



