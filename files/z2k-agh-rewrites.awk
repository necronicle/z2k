# Bounded editor for AGH's serialized block YAML, not a general YAML parser.
# Unsupported structures fail closed. Foreign item bytes are retained verbatim.
function scalar(s) {
    sub(/[ \t]+#.*/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s)
    if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s=substr(s,2,length(s)-2)
    return s
}
function spaces(n, s) { s=""; while(n-- > 0) s=s " "; return s }
function indent(s) { match(s,/[^ ]/); return RSTART-1 }
function conflict(d,h, suffix) {
    d=tolower(d); h=tolower(h); sub(/\.$/,"",d); sub(/\.$/,"",h)
    if (d==h) return 1
    if (substr(d,1,2)=="*.") {
        suffix=substr(d,2)
        return length(h)>length(suffix) && substr(h,length(h)-length(suffix)+1)==suffix
    }
    return 0
}
function flush_item( k,j) {
    if (!item) return
    if (!domain || !answer) bad=1
    k=tolower(domain) "\t" answer
    # Only an unmodified owned item is removable. Extra settings mean user edit.
    if (owned[k]>0 && !extra) {
        owned[k]--; removed[k]++
        ownedstart[item]=k
        for(j=item;j<NR;j++) ownedline[j]=k
    }
    else {
        foreign[++nf]=domain
        for(j=item;j<NR;j++) keep[j]=1
    }
    item=0; domain=""; answer=""; extra=0
}
BEGIN {
    while ((getline s < ledger)>0) owned[s]++
    close(ledger)
    while ((getline s < desired)>0) { want[s]=1; split(s,a,"\t"); names[a[1]]=1 }
    close(desired)
}
{
    line[NR]=$0
    if ($0 ~ /\t/) bad=1
    if ($0 ~ /^[^ #][^:]*:/) { section=$0; sub(/:.*/,"",section) }
    if ($0 ~ /^[ ]+rewrites:/ && (section=="filtering" || section=="dns")) {
        if (start) bad=1
        start=NR; base=indent($0); head=$0; inrw=1
        tail=$0; sub(/^[ ]*rewrites:[ ]*/,"",tail)
        if (tail!="" && tail!="[]") bad=1
        next
    }
    if (inrw) {
        ind=indent($0)
        if ($0 !~ /^[ ]*(#.*)?$/ && ind<=base && $0 !~ /^[ ]*-/) {
            flush_item(); finish=NR-1; inrw=0
        } else if ($0 ~ /^[ ]*-[ ]+domain:/) {
            flush_item(); item=NR
            if(have_seqindent && seqindent!=ind) bad=1
            seqindent=ind; have_seqindent=1
            domain=scalar(substr($0,index($0,"domain:")+7)); next
        } else if (item && $0 ~ /^[ ]+answer:/) {
            answer=scalar(substr($0,index($0,"answer:")+7)); next
        } else if (item && $0 ~ /^[ ]+enabled:[ ]*true[ ]*$/) { next
        } else if (item && $0 ~ /^[ ]+enabled:[ ]*false[ ]*$/) { extra=1; next
        } else if ($0 ~ /^[ ]*(#.*)?$/) { keep[NR]=1; next
        } else { bad=1; extra=1 }
    }
    if ($0 ~ /^[ ]+rewrites_enabled:[ ]*false/) disabled=1
}
END {
    if (inrw) { NR++; flush_item(); NR--; finish=NR }
    if (bad) exit 2
    if(presentfile!="") for(k in removed) print k > presentfile
    for(k in want) {
        split(k,a,"\t"); blocked=0
        for(j=1;j<=nf;j++) if(conflict(foreign[j],a[1])) blocked=1
        if(blocked) conflicts[a[1]]=1
        else { newown[k]=1; count++ }
    }
    # Preserve serialized bytes for retained owned items. Equality is semantic;
    # AGH may quote values, reorder items or emit enabled:true on shutdown.
    for(i=1;i<=NR;i++) if(i in ownedstart) {
        k=ownedstart[i]
        if((k in newown) && !(k in retained)) {
            retained[k]=1
            for(j=i;j<=NR && ownedline[j]==k;j++) keep[j]=1
        }
    }
    if (disabled && count) exit 3
    for(h in conflicts) print h > conflictfile
    for(k in newown) print k > newledger
    if (!start) {
        if (!count) { for(i=1;i<=NR;i++) print line[i]; exit }
        # Missing key is supported only in an existing filtering mapping.
        for(i=1;i<=NR;i++) if(line[i]=="filtering:") at=i
        if(!at) exit 2
        for(i=1;i<=NR;i++) {
            print line[i]
            if(i==at) {
                print "  rewrites:"
                while((getline s < desired)>0) if(s in newown) { split(s,a,"\t"); print "    - domain: "a[1]; print "      answer: "a[2]; print "      enabled: true" }
                close(desired)
            }
        }
        exit
    }
    # Stable insertion order comes from desired (sorted by caller).
    prefix=spaces(base)
    seqprefix=spaces(have_seqindent ? seqindent : base+2)
    any=count
    for(i=start+1;i<=finish;i++) if(keep[i] && line[i] !~ /^[ ]*(#.*)?$/) any++
    for(i=1;i<=NR;i++) {
        if(i==start) {
            print prefix "rewrites:" (any ? "" : " []")
            for(j=start+1;j<=finish;j++) if(keep[j]) print line[j]
            while ((getline s < desired)>0) if((s in newown) && !(s in retained)) {
                split(s,a,"\t"); print seqprefix "- domain: "a[1]; print seqprefix "  answer: "a[2]; print seqprefix "  enabled: true"
            }
            close(desired)
        } else if(i<start || i>finish) print line[i]
    }
}
