#!/bin/sh
#Put in /etc/adblock.sh
#Block ads, malware, etc.

#### CONFIG SECTION ####

# Only block wireless ads? Y/N
ONLY_WIRELESS="N"

TMPDIR="/tmp"

# IPv6 support? Y/N
IPV6="N"

# Need SSL websites?
SSL="N"

# Try to transparently serve pixel response?
#   If enabled, understand the consequences and mechanics of this setup
TRANS="N"

# Exempt an ip range
EXEMPT="N"
START_RANGE="192.168.1.0"
END_RANGE="192.168.1.255"

# Redirect endpoint
ENDPOINT_IP4="0.0.0.0 "
ENDPOINT_IP6="::"

#Change the cron command to what is comfortable, or leave as is
CRON="0 1 * * * sh /etc/adblock.sh \n0 2 * * * [ -s /etc/block.hosts ] || sh /etc/adblock.sh"

#types

#Remove Empty Newlines
RMENL="sed '/^\s*$/d'"

#Starts with 127.0.0.1
FT127=" | awk -v r="\"$ENDPOINT_IP4\"" '{sub(/^127.0.0.1 /, r)} $0 ~ "^"r'"

#Starts with 0.0.0.0
FT0="awk -v r="\"$ENDPOINT_IP4\"" '{sub(/^0.0.0.0 /, r)} $0 ~ "^"r'"

#Is Raw
ISRAW="awk -v r="\"$ENDPOINT_IP4\"" '{sub(/^/, r)} $0 ~ "^"r'"

#Has comments '#' and is a raw eg: 'www.google.com'
FTR="sed -r 's/[[:space:]]|[\[!#/:;_].*|[0-9\.]*localhost.*//g; s/[\^#/:;_\.\t ]*$//g' | $ISRAW"

#Has directories
FTWD="sed -e 's|^[^/]*//||' -e 's|/.*$||' | $ISRAW"

#adblock plus
FTABP="sed -e '/^\|\|/! s/.*//; /\^$/! s/.*//; s/\^$//g; /[\.]/! s/.*//; s/^[\|]\{1,2\}//g' | $RMENL | awk '{gsub("ws*:\/\/*", "");print}' | awk '{gsub("@@\|\|", "");print}' | $ISRAW"

#ABP Rules
FTABPR="sed 's/..//' | sed 's/.............$//' | awk '{gsub("^\$popu", "");print}' | awk '{gsub("^\$domain", "");print}' | $ISRAW"

#### END CONFIG ####

#### FUNCTIONS ####

cleanup()
{
    #Delete files used to build list to free up the limited space
    echo 'Cleaning up...'
    rm -f $TMPDIR/block.build.list
    rm -f $TMPDIR/block.build.before
}

install_dependencies()
{
    #Need iptables-mod-nat-extra installed
    if opkg list-installed | grep -q iptables-mod-nat-extra
    then
        echo 'iptables-mod-nat-extra is installed!'
    else
        echo 'Updating package list...'
        opkg update > /dev/null
        echo 'Installing iptables-mod-nat-extra...'
        opkg install iptables-mod-nat-extra > /dev/null
    fi

    #Need iptable-mod-iprange for exemption
    if [ "$EXEMPT" = "Y" ]
    then
        if opkg list-installed | grep -q iptables-mod-iprange
        then
            echo 'iptables-mod-iprange installed'
        else
            echo 'Updating package list...'
            opkg update > /dev/null
            echo 'Installing iptables-mod-iprange...'
            opkg install iptables-mod-iprange > /dev/null
        fi
    fi

    #Need wget for https websites
    if [ "$SSL" = "Y" ]
    then
        if opkg list-installed wget | grep -q wget
        then
            if wget --version | grep -q +ssl
            then
                echo 'wget (with ssl) found'
            else
                # wget without ssl, need to reinstall full wget
                opkg update > /dev/null
                opkg install wget --force-reinstall > /dev/null
            fi
        else
            echo 'Updating package list...'
            opkg update > /dev/null
            echo 'Installing wget (with ssl)...'
            opkg install wget > /dev/null
        fi
    fi
}

add_config()
{
    if [ "$ONLY_WIRELESS" = "Y" ]
    then
        echo 'Wireless only blocking!'
        if [ "$EXEMPT" = "Y" ]
        then
            echo 'Exempting some ips...'
            FW1="iptables -t nat -I PREROUTING -m iprange ! --src-range $START_RANGE-$END_RANGE -i wlan+ -p tcp --dport 53 -j REDIRECT --to-ports 53"
            FW2="iptables -t nat -I PREROUTING -m iprange ! --src-range $START_RANGE-$END_RANGE -i wlan+ -p udp --dport 53 -j REDIRECT --to-ports 53"
        else
            FW1="iptables -t nat -I PREROUTING -i wlan+ -p tcp --dport 53 -j REDIRECT --to-ports 53"
            FW2="iptables -t nat -I PREROUTING -i wlan+ -p udp --dport 53 -j REDIRECT --to-ports 53"
        fi
    else
        if [ "$EXEMPT" = "Y" ]
        then
            echo "Exempting some ips..."
            FW1="iptables -t nat -I PREROUTING -m iprange ! --src-range $START_RANGE-$END_RANGE -p tcp --dport 53 -j REDIRECT --to-ports 53"
            FW2="iptables -t nat -I PREROUTING -m iprange ! --src-range $START_RANGE-$END_RANGE -p udp --dport 53 -j REDIRECT --to-ports 53"
        else
            FW1="iptables -t nat -I PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53"
            FW2="iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53"
        fi
    fi

    echo 'Updating config...'

    #Update DHCP config
    uci add_list dhcp.@dnsmasq[0].addnhosts=/etc/block.hosts > /dev/null 2>&1 && uci commit

    #Add to crontab
    echo "$CRON" >> /etc/crontabs/root

    #Update dnsmasq config for Tor
    TOR=`uci get tor.global.enabled 2> /dev/null`
    if [ "$TOR" == "1" ]
    then
        TORPORT=`uci get tor.client.dns_port`
        TORIP="127.0.0.1:$TORPORT"
        uci set dhcp.@dnsmasq[0].noresolv='1' > /dev/null &2>1 && uci commit
        uci add_list dhcp.@dnsmasq[0].server="$TORIP" > /dev/null &2>1 && uci commit
    fi

    # Add firewall rules
    echo "$FW1" >> /etc/firewall.user
    echo "$FW2" >> /etc/firewall.user

    # Provide hint if localservice is 1
    LS=`uci get dhcp.@dnsmasq[0].localservice 2> /dev/null`
    if [ "$LS" == "1" ]
    then
        echo "HINT: localservice is set to 1"
        echo "    Adblocking (and router DNS) over a VPN may not work"
        echo "    To allow VPN router DNS, manually set localservice to 0"
    fi


    # Determining uhttpd/httpd_gargoyle for transparent pixel support
    if [ "$TRANS" = "Y" ]
    then
        if [ ! -e "/www/1.gif" ]
        then
            /usr/bin/wget -O /www/1.gif http://upload.wikimedia.org/wikipedia/commons/c/ce/Transparent.gif  > /dev/null
        fi
        if [ -s "/usr/sbin/uhttpd" ]
        then
            #The default is none, so I don't want to check for it, so just write it
            echo "uhttpd found..."
            echo "updating server error page to return transparent pixel..."
            uci set uhttpd.main.error_page="/1.gif" && uci commit
        elif [ -s "/usr/sbin/httpd_gargoyle" ]
        then
            # Write without testing
            echo "httpd_gargoyle found..."
            echo "updating server error page to return transparent pixel..."
            uci set httpd_gargoyle.server.page_not_found_file="1.gif" && uci commit
        else
            echo "Cannot find supported web server..."
        fi
    fi
}

add_whitelist()
{
    echo 'Downloading white lists...'
    [ -s /etc/white.list ] ||
    wget -qO- "https://raw.githubusercontent.com/boutetnico/url-shorteners/master/list.txt" > /etc/white.list
    }

update_blocklist()
{
    #Delete the old block.hosts to make room for the updates
    rm -f /etc/block.hosts

    # Correct endpoint for transparent pixel response
    if [ "$TRANS" = "Y" ] && [ -e "/www/1.gif" ] && ([ -s "/usr/sbin/uhttpd" ] || [ -s "/usr/sbin/httpd_gargoyle" ])
    then
        ENDPOINT_IP4=$(uci get network.lan.ipaddr)
        if [ "$IPV6" = "Y" ]
        then
            ENDPOINT_IP6=$(uci get network.lan6.ipaddr)
        fi
    fi
    echo 'Downloading hosts lists...'
    #Download and process the files needed to make the lists (enable/add more, if you want)
    curl  "https://adaway.org/hosts.txt"|$FT127 > $TMPDIR/block.build.list
    curl  "http://www.mvps.org/winhelp2002/hosts.txt" | $FT0 >> $TMPDIR/block.build.list
    curl  "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/win10/spy.txt"| $FT0 >> $TMPDIR/block.build.list
    curl  "https://www.malwaredomainlist.com/hostslist/hosts.txt" | $FT127 >> $TMPDIR/block.build.list
    curl  "http://hosts-file.net/ad_servers.txt" | $FT127 >> $TMPDIR/block.build.list
    curl  "https://zeustracker.abuse.ch/blocklist.php?download=domainblocklist" | $FTR >> $TMPDIR/block.build.list
    curl  "http://someonewhocares.org/hosts/hosts" | $FT127 >> $TMPDIR/block.build.list
    curl  "https://raw.githubusercontent.com/Dawsey21/Lists/master/main-blacklist.txt" | $FTR >> $TMPDIR/block.build.list
    curl  "https://openphish.com/feed.txt" | $FTWD >> $TMPDIR/block.build.list
    curl  "https://mirror.cedia.org.ec/malwaredomains/justdomains" | $FTR >> $TMPDIR/block.build.list
    curl  "https://feodotracker.abuse.ch/blocklist/?download=ipblocklist" | $FTR >> $TMPDIR/block.build.list
    curl  "https://www.dshield.org/feeds/suspiciousdomains_Low.txt" | $FTR >> $TMPDIR/block.build.list
    curl  "https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt" | tail +2 | $FTR >> $TMPDIR/block.build.list
    curl  "https://easylist-downloads.adblockplus.org/ruadlist+easylist.txt" | $FTABP >> $TMPDIR/block.build.list
    curl  "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext" | $FT127 >> $TMPDIR/block.build.list
    curl  "http://www.hostsfile.org/Downloads/hosts.txt" | $FT127 >> $TMPDIR/block.build.list
    curl  "https://raw.githubusercontent.com/ABPindo/indonesianadblockrules/master/abpindo_adservers.txt" |  >> $TMPDIR/block.build.list
    curl  "https://gist.githubusercontent.com/Maysora/25dca985de1ed6d8eb4c95081d54667b/raw/369929e39531cdac8661df1f8bf430a76ef4e73d/hosts"| $FT0 >> $TMPDIR/block.build.list
    #Add black list, if non-empty
    if [ -s "/etc/black.list" ]
    then
        echo 'Adding blacklist...'
        awk -v r="$ENDPOINT_IP4" '/^[^#]/ { print r,$1 }' /etc/black.list >> $TMPDIR/block.build.list
    fi

    echo 'Sorting lists...'

    #Sort the download/black lists
    #| sed 's/0.0.0.0 */0.0.0.0 /g' | sed 's/0.0.0.0 @@||*/0.0.0.0 /g' |sed 's/\/\///g' | sed '/0.0.0.0 #/d' | sed '/0.0.0.0 :/d' | sed -e '1d'
    awk '{sub(/\r$/,"");print $1,$2}' $TMPDIR/block.build.list|sort -u   > $TMPDIR/block.build.before

    #Filter (if applicable)
    if [ -s "/etc/white.list" ]
    then
        #Filter the blacklist, suppressing whitelist matches
        #  This is relatively slow =-(
        echo 'Filtering white list...'
        egrep -v "^[[:space:]]*$" /etc/white.list | awk '/^[^#]/ {sub(/\r$/,"");print $1}' | grep -vf - $TMPDIR/block.build.before > /etc/block.hosts
    else
        cat $TMPDIR/block.build.before > /etc/block.hosts
    fi

    if [ "$IPV6" = "Y" ]
    then
        safe_pattern=$(printf '%s\n' "$ENDPOINT_IP4" | sed 's/[[\.*^$(){}?+|/]/\\&/g')
        safe_addition=$(printf '%s\n' "$ENDPOINT_IP6" | sed 's/[\&/]/\\&/g')
        echo 'Adding ipv6 support...'
        sed -i -re "s/^(${safe_pattern}) (.*)$/\1 \2\n${safe_addition} \2/g" /etc/block.hosts
    fi
}

restart_firewall()
{
    echo 'Restarting firewall...'
    if [ -s "/usr/lib/gargoyle/restart_firewall.sh" ]
    then
        /usr/lib/gargoyle/restart_firewall.sh > /dev/null 2>&1
    else
        /etc/init.d/firewall restart > /dev/null 2>&1
    fi
}

restart_dnsmasq()
{
    if [ "$1" -eq "0" ]
    then
        echo 'Re-reading blocklist'
        killall -HUP dnsmasq
    else
        echo 'Restarting dnsmasq...'
        /etc/init.d/dnsmasq restart
    fi
}

restart_http()
{
    if [ -s "/usr/sbin/uhttpd" ]
    then
        echo 'Restarting uhttpd...'
        /etc/init.d/uhttpd restart
    elif [ -s "/usr/sbin/httpd_gargoyle" ]
    then
        echo 'Restarting httpd_gargoyle...'
        /etc/init.d/httpd_gargoyle restart
    fi
}
restart_cron()
{
    echo 'Restarting cron...'
    /etc/init.d/cron restart > /dev/null 2>&1
}

remove_config()
{
    echo 'Reverting config...'

    # Remove addnhosts
    uci del_list dhcp.@dnsmasq[0].addnhosts=/etc/block.hosts > /dev/null 2>&1 && uci commit

    # Remove cron entry
    sed -i '/adblock/d' /etc/crontabs/root

    # Remove firewall rules
    sed -i '/--to-ports 53/d' /etc/firewall.user

    # Remove Tor workarounds
    uci del_list dhcp.@dnsmasq[0].server > /dev/null 2>&1 && uci commit
    uci set dhcp.@dnsmasq[0].noresolv='0' > /dev/null 2>&1 && uci commit

    # Remove proxying
    uci delete uhttpd.main.error_page > /dev/null 2>&1 && uci commit
    uci set httpd_gargoyle.server.page_not_found_file="login.sh" > /dev/null 2>&1 && uci commit
}


toggle()
{
    # Check for cron as test for on/off
    if grep -q "adblock" /etc/crontabs/root
    then
        # Turn off
        echo 'Turning off!'
        remove_config
    else
        # Turn on
        echo 'Turning on!'
        add_config
    fi

    # Restart services
    restart_firewall
    restart_dnsmasq 1
    restart_http
    restart_cron
}

#### END FUNCTIONS ####

### Options parsing ####

case "$1" in
    # Toggle on/off
    "-t")
        toggle
        ;;
    #First time run
    "-f")
        install_dependencies
        add_config
        add_whitelist
        update_blocklist
        restart_firewall
        restart_dnsmasq 1
        restart_http
        restart_cron
        cleanup
        ;;
    #Reinstall
    "-r")
        remove_config
        install_dependencies
        add_config
        add_whitelist
        update_blocklist
        restart_firewall
        restart_dnsmasq 1
        restart_http
        restart_cron
        cleanup
        ;;
    #Default updates blocklist only
    *)
        add_whitelist
        update_blocklist
        restart_dnsmasq 0
        cleanup
        ;;
esac

#### END OPTIONS ####

exit 0
