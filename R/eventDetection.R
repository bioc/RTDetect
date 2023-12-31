#' Detecting retrotranscript insertion in nuclear genomes.
#'
#' @details
#' This function searches for retroposed transcripts by identifying breakpoints supporting 
#' intronic deletions and fusions between exons and remote loci.
#' Only BND notations are supported at the current stage.
#' @param gr A GRanges object
#' @param genes TxDb object of genes. hg19 and hg38 are supported in the current version.
#' @param maxgap The maxium distance allowed on the reference genome between the paired exon boundries.
#' @param minscore The minimum proportion of intronic deletions of a transcript should be identified.
#' @return A GRangesList object, named insSite and rt, reporting breakpoints supporting insert sites and 
#' retroposed transcripts respectively. 'exon' and 'txs' in the metadata columns report exon_id and transcript_name from the 'genes' object.
#' @examples
#' library(TxDb.Hsapiens.UCSC.hg19.knownGene)
#' genes <- TxDb.Hsapiens.UCSC.hg19.knownGene
#' vcf.file <- system.file("extdata", "diploidSV.vcf",
#'                          package = "RTDetect")
#' vcf <- VariantAnnotation::readVcf(vcf.file, "hg19")
#' gr <- breakpointRanges(vcf, nominalPosition=TRUE)
#' rt <- rtDetect(gr, genes, maxgap=30, minscore=0.6)
#' @export
#' 
rtDetect <- function(gr, genes, maxgap=100, minscore=0.4){
    #message("rtDetect")
    #check args
    assertthat::assert_that(is(gr, "GRanges"), msg = "gr should be a GRanges object")
    assertthat::assert_that(length(gr)>0, msg = "gr can't be empty")
    assertthat::assert_that(is(genes, "TxDb"), msg = "genes should be a TxDb object")
    
    #prepare annotation exons
    GenomeInfoDb::seqlevelsStyle(genes) <- GenomeInfoDb::seqlevelsStyle(gr)[1]
    genes <- GenomeInfoDb::keepSeqlevels(genes, seqlevels(genes)[seq_len(24)], pruning.mode = "coarse")
    exons <- exons(genes, columns=c("exon_id", "tx_id", "tx_name","gene_id"))
    
    #find exon-SV overlaps:
    hits.start <- findOverlaps(gr, exons, maxgap = maxgap, type = "start", ignore.strand = TRUE)
    hits.end <- findOverlaps(partner(gr), exons, maxgap = maxgap, type = "end", ignore.strand = TRUE)
    
    # 1.return breakpoints overlapping with exons on both ends (>=2 exons)
    hits <- dplyr::inner_join(dplyr::as_tibble(hits.start), dplyr::as_tibble(hits.end), by="queryHits")
    #mcols(exons)[hits$subjectHits.x, "gene_id"] == mcols(exons)[hits$subjectHits.y, "gene_id"]
    same.tx <- sapply(Reduce(intersect, list(mcols(exons)[hits$subjectHits.x, 'tx_id'], 
                                             mcols(exons)[hits$subjectHits.y, 'tx_id'])),length)!=0
    hits.tx <- hits[same.tx,]
    
    # 2.return breakpoints of insertionSite-exon 
    hits.insSite <- hits[!same.tx,] %>%
        dplyr::bind_rows(dplyr::anti_join(dplyr::as_tibble(hits.start), dplyr::as_tibble(hits.end), by='queryHits')) %>%
        dplyr::bind_rows(dplyr::anti_join(dplyr::as_tibble(hits.end), dplyr::as_tibble(hits.start), by='queryHits'))
    
    # hits.insSite <- rbind(hits[!same.tx,],
    #                       anti_join(dplyr::as_tibble(hits.start), dplyr::as_tibble(hits.end), by='queryHits'),
    #                       anti_join(dplyr::as_tibble(hits.end), dplyr::as_tibble(hits.start), by='queryHits'))
    
    if (nrow(hits.tx)+nrow(hits.insSite)==0) {
        message("There is no retroposed gene detected.")
        return(GRanges())
    }else{
        # 3.filter exon-exon junctions by minscore(>=2 exons)
        txs <- mapply(intersect, exons[hits.tx$subjectHits.x]$tx_name, exons[hits.tx$subjectHits.y]$tx_name)
        rt.gr<- c(gr[hits.tx$queryHits], partner(gr)[hits.tx$queryHits])
        rt.gr$exon <- c(exons[hits.tx$subjectHits.x]$exon_id, exons[hits.tx$subjectHits.y]$exon_id)
        rt.gr$txs <- c(IRanges::CharacterList(txs), IRanges::CharacterList(txs))
        rt.gr <- rt.gr[!sapply(rt.gr$txs, rlang::is_empty)]
        
        #message("annotate overlapping exons")
        #combine matching exons and transcripts of the same breakend
        names <- unique(names(rt.gr))
        rt.txs <- sapply(names, function(x) {Reduce(union, rt.gr[names(rt.gr)==x]$txs)})
        rt.exons <- sapply(names, function(x) {Reduce(union, rt.gr[names(rt.gr)==x]$exon)})
        rt.gr$txs <- rt.txs[names(rt.gr)]
        rt.gr$exons <- rt.exons[names(rt.gr)]
        #remove duplicate breakend records
        rt.gr <- rt.gr[!duplicated(names(rt.gr))]
        #unique() and duplicated() for granges compare RANGES, not names
        # rt.gr <- rt.gr[rt.gr$exons != partner(rt.gr)$exons]
        
        rt.gr
        
        #RT filter 1: breakpoint should have at least one set of matching exon
        rt.gr <- rt.gr[!mapply(identical, partner(rt.gr)$exons, rt.gr$exons) | 
                           (mapply(identical, partner(rt.gr)$exons, rt.gr$exons) & sapply(rt.gr$exons, length)>1)]
        
        #RT filter 2:minimal proportion of exon-exon detected for a transcript
        tx.rank <- .scoreByTranscripts(genes, unlist(rt.gr$txs)) 
        #dataframe of valid retro transcripts
        tx.rank <- tx.rank[tx.rank$score >= minscore,]
        #remove rows and transcripts which are not in the tx.rank
        rt.gr <- rt.gr[stringr::str_detect(unstrsplit(rt.gr$txs), paste(tx.rank$tx_name, collapse = "|"))]
        rt.gr$txs <- mapply('[', rt.gr$txs, mapply(stringr::str_detect, rt.gr$txs, paste(tx.rank$tx_name, collapse = "|")))
        
        
        #select insertion site by minscore (tx.rank)
        # hits.start.idx <- stringr::str_detect(unstrsplit(exons[S4Vectors::subjectHits(hits.start)]$tx_name), paste(tx.rank$tx_name, collapse = "|"))
        # hits.end.idx <- stringr::str_detect(unstrsplit(exons[S4Vectors::subjectHits(hits.end)]$tx_name),paste(tx.rank$tx_name, collapse = "|"))
        
        # 4.filter insertion site junctions, reduce duplications
        #junctions with only one side overlapping with exons:
        idx <- dplyr::bind_rows(dplyr::anti_join(dplyr::as_tibble(hits.start), dplyr::as_tibble(hits.end), by='queryHits'),
                                dplyr::anti_join(dplyr::as_tibble(hits.end), dplyr::as_tibble(hits.start), by='queryHits'))
        
        insSite.gr <- c(gr[hits[!same.tx,]$queryHits], partner(gr)[hits[!same.tx,]$queryHits], gr[idx$queryHits])
        insSite.gr$exons <- c(exons[hits[!same.tx,]$subjectHits.x]$exon_id, exons[hits[!same.tx,]$subjectHits.y]$exon_id,
                              exons[idx$subjectHits]$exon_id)
        insSite.gr$txs <- c(exons[hits[!same.tx,]$subjectHits.x]$tx_name, exons[hits[!same.tx,]$subjectHits.y]$tx_name,
                            exons[idx$subjectHits]$tx_name)
        insSite.gr <- insSite.gr[!sapply(insSite.gr$txs, rlang::is_empty)]
        #combine matching exons and transcripts of the same breakend
        names <- unique(names(insSite.gr))
        insSite.txs <- sapply(names, function(x) {Reduce(union, insSite.gr[names(insSite.gr)==x]$txs)})
        insSite.exons <- sapply(names, function(x) {Reduce(union, insSite.gr[names(insSite.gr)==x]$exons)})
        insSite.gr$txs <- insSite.txs[names(insSite.gr)]
        insSite.gr$exons <- insSite.exons[names(insSite.gr)]
        insSite.gr <- insSite.gr[!duplicated(names(insSite.gr))]
        insSite.gr <- insSite.gr[!names(insSite.gr) %in% names(rt.gr)]
        insSite.gr <- c(insSite.gr, gr[insSite.gr[!insSite.gr$partner %in% names(insSite.gr)]$partner])
        insSite.gr$rtFound <- mapply(stringr::str_detect, insSite.gr$txs, paste(tx.rank$tx_name, collapse = "|"))
        insSite.gr$rtFoundSum <- sapply(insSite.gr$rtFound, function(x) {sum(x) > 0})
        
        # 5.create one GrangesList per gene
        #get all genes detected
        rt.gr$gene_symbol <- .txs2genesym(rt.gr$txs)
        insSite.gr$gene_symbol <- .txs2genesym(insSite.gr$txs)
        l_gene_symbol <- unique(c(unlist(rt.gr$gene_symbol), unlist(insSite.gr$gene_symbol)))
        
        #RT GRangesList by gene
        rt.gr.idx <- lapply(l_gene_symbol, function(gs) 
            sapply(rt.gr$gene_symbol, function(x) gs %in% x))
        rt.grlist <- stats::setNames(lapply(rt.gr.idx, 
                                     function(i) list(rt=rt.gr[i])), l_gene_symbol)
        
        #InsSite GRangesList by gene
        insSite.gr.idx <- lapply(l_gene_symbol, function(gs) 
            sapply(insSite.gr$gene_symbol, function(x) gs %in% x))
            #including partnered insSite bnds which don't have a gene symbol labelling (NA)
        insSite.grlist <- stats::setNames(lapply(insSite.gr.idx, 
                                          function(i) list(insSite=c(insSite.gr[i],
                                                                     partner(insSite.gr)[i]))), 
                                   l_gene_symbol)
        # insSite.grlist <- lapply(insSite.gr.idx, function(i) insSite.gr[i])
        # names(insSite.grlist) <- l_gene_symbol
        
        #group inssite and rt as one GRangesList
        gr.list <- S4Vectors::pc(rt.grlist, insSite.grlist)
        gr.list <- lapply(gr.list, function(x) stats::setNames(x, c('junctions', 'insSite')))
        
        #TODO: add L1/Alu annotation for insertion site filtering.
        
        #NOTE: GrangesList require all GRanges share the same mcols!
        #return(GRangesList(insSite = insSite.gr, rt = rt.gr))
        #return(GRangesList(insSite=GRangesList(insSite.grlist), rt=GRangesList(rt.grlist)))
        return(gr.list)
        
    }
}



